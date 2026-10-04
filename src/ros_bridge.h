// RosBridge: a Godot node that talks to the UWB fleet over ROS 2.
//
// rclcpp runs in its own context and executor thread; callbacks only store the
// latest values under a mutex and GDScript polls them every frame.
//
//   /uwb_ekf/<robot>/pose         PoseStamped   robot pose (pose_topic_format)
//   /uwb/<robot>/pose             PoseStamped   raw UWB pose (raw_pose_topic_format): only its
//                                               arrival is used. The EKF keeps extrapolating when the
//                                               tag goes silent (power loss), so EKF poses are ignored
//                                               while the raw pose is older than raw_timeout.
//   /uwb_ekf/<robot>/pose_valid   Bool (latched) false while the tag is silent (uwb_ekf_adapter);
//                                               EKF poses are ignored then as well
//   /uwb/anchors                  MarkerArray   anchor positions, UWB frame (linktrack_node)
//   display_anchors_topic         MarkerArray   optional: the same anchors in another frame
//                                               (e.g. /uwb_viz/rm_0/anchors of uwb_mocap_viz.py)
//   /uwb_nav/<robot>/markers      MarkerArray   nav goal + status text (uwb_goal_nav.py)
//   /<robot>/odometry/filtered    Odometry      car IMU yaw (ENU, from magnetic east; imu_topic_format)
//   /<robot>/imu/mag_state        String        LOCKED / HOLD / REJECTED
//   /uwb_ekf/<robot>/heading_valid Bool (latched) the pose orientation carries a real
//                                               UWB-frame yaw; without it the orientation is ignored
//   /uwb_nav/<robot>/goal_pose    PoseStamped   <- move orders (z: UWB height for flying robots)
//   /uwb_nav/<robot>/cancel       Empty         <- stop orders
//   /<robot>/cmd_vel              Twist         <- manual drive
//   /uwb_nav/select               String        <- selection, keeps RViz/uwb_fleet in sync
//
// Display frame: origin at anchor origin_anchor (A0), z up from the floor (UWB z -
// floor_z), and
//   - ENU (once set_enu_rotation() was called): x magnetic east, y magnetic north.
//     A UWB-frame direction psi has the ENU yaw h * (psi - theta), h = handedness of
//     the UWB frame (-1: mirrored), theta = UWB angle of magnetic east.
//   - otherwise: +x towards anchor axis_anchor (A1). Anchors, poses and nav
// goals are mapped into it; move orders are mapped back into the UWB frame before
// they are sent, so uwb_goal_nav.py keeps working in UWB coordinates.
//
// With display_anchors_topic set, the display frame is that topic's frame instead:
// a 2D affine map UWB -> display (rotation, translation, scale, mirror) is fitted
// from the anchors seen in both topics, matched by id.
//
// Robots: the names in `robots`, plus (auto_discover) every <name> seen in a topic
// matching pose_topic_format or raw_pose_topic_format, checked every 2 s, so new
// robots (rm_7, dog_0, ...) show up without a restart.
//
// All positions are in ROS coordinates (x forward, z up), conversion to Godot is
// done in GDScript. Callbacks run on a multi-threaded executor.

#pragma once

#include <godot_cpp/classes/node.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_string_array.hpp>
#include <godot_cpp/variant/string.hpp>
#include <godot_cpp/variant/vector2.hpp>

#include <chrono>
#include <map>
#include <set>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

#include <geometry_msgs/msg/pose_stamped.hpp>
#include <geometry_msgs/msg/twist.hpp>
#include <nav_msgs/msg/odometry.hpp>
#include <rclcpp/rclcpp.hpp>
#include <std_msgs/msg/bool.hpp>
#include <std_msgs/msg/empty.hpp>
#include <std_msgs/msg/string.hpp>
#include <visualization_msgs/msg/marker_array.hpp>

namespace robomaster_gui
{

class RosBridge : public godot::Node
{
    GDCLASS(RosBridge, godot::Node)

public:
    RosBridge() = default;
    ~RosBridge() override;

    // lifecycle
    bool start();
    void stop();
    bool is_running() const;

    // polled state
    godot::Dictionary get_robot_states() const;
    godot::Array get_anchors() const;
    godot::Dictionary get_stats() const;
    godot::String get_frame_info() const;
    godot::Vector2 to_uwb_xy(const godot::Vector2& display) const;
    godot::Vector2 to_display_xy(const godot::Vector2& uwb) const;
    bool is_frame_ready() const;

    // commands
    void send_goal(const godot::String& robot, double x, double y, double yaw);
    void send_goal_3d(const godot::String& robot, double x, double y, double height);
    void cancel_goal(const godot::String& robot);
    void send_cmd_vel(const godot::String& robot, double vx, double vy, double wz);
    void publish_selection(const godot::PackedStringArray& robots);

    // properties
    void set_robots(const godot::PackedStringArray& robots) { robots_ = robots; }
    void set_auto_discover(bool v) { auto_discover_ = v; }
    bool get_auto_discover() const { return auto_discover_; }
    godot::PackedStringArray get_robots() const { return robots_; }
    void set_node_name(const godot::String& v) { node_name_ = v; }
    godot::String get_node_name() const { return node_name_; }
    void set_frame_id(const godot::String& v) { frame_id_ = v; }
    godot::String get_frame_id() const { return frame_id_; }
    void set_pose_topic_format(const godot::String& v) { pose_topic_format_ = v; }
    godot::String get_pose_topic_format() const { return pose_topic_format_; }
    void set_raw_pose_topic_format(const godot::String& v) { raw_pose_topic_format_ = v; }
    godot::String get_raw_pose_topic_format() const { return raw_pose_topic_format_; }
    void set_raw_timeout(double v) { raw_timeout_ = v; }
    double get_raw_timeout() const { return raw_timeout_; }
    void set_cmd_topic_format(const godot::String& v) { cmd_topic_format_ = v; }
    godot::String get_cmd_topic_format() const { return cmd_topic_format_; }
    void set_imu_topic_format(const godot::String& v) { imu_topic_format_ = v; }
    godot::String get_imu_topic_format() const { return imu_topic_format_; }
    void set_anchors_topic(const godot::String& v) { anchors_topic_ = v; }
    godot::String get_anchors_topic() const { return anchors_topic_; }
    void set_display_anchors_topic(const godot::String& v) { display_anchors_topic_ = v; }
    godot::String get_display_anchors_topic() const { return display_anchors_topic_; }
    void set_origin_anchor(int v) { origin_anchor_ = v; }
    int get_origin_anchor() const { return origin_anchor_; }
    void set_axis_anchor(int v) { axis_anchor_ = v; }
    int get_axis_anchor() const { return axis_anchor_; }
    void set_floor_z(double v) { floor_z_ = v; }
    double get_floor_z() const { return floor_z_; }
    void set_enu_rotation(double theta, double handedness);
    void clear_enu_rotation();
    bool is_enu() const;

protected:
    static void _bind_methods();

private:
    using Clock = std::chrono::steady_clock;
    Clock::time_point t0_ = Clock::now();

    struct Robot
    {
        bool has_pose = false;
        double x = 0, y = 0, z = 0, yaw = 0;
        bool heading_valid = false;     // /uwb_ekf/<robot>/heading_valid: the pose yaw is real
        bool pose_valid = true;
        Clock::time_point invalid_stamp;
        bool has_raw = false;
        double raw_z = 0;               // raw UWB z (height for flying robots)
        Clock::time_point raw_stamp;
        uint64_t seq = 0;
        Clock::time_point stamp;
        bool has_imu = false;
        double imu_yaw = 0;
        Clock::time_point imu_stamp;
        std::string mag_state;
        bool has_goal = false;
        double gx = 0, gy = 0;
        std::string status;
        rclcpp::Publisher<geometry_msgs::msg::PoseStamped>::SharedPtr goal_pub;
        rclcpp::Publisher<std_msgs::msg::Empty>::SharedPtr cancel_pub;
        rclcpp::Publisher<geometry_msgs::msg::Twist>::SharedPtr cmd_pub;
    };

    struct Anchor
    {
        double x, y, z;
        Clock::time_point stamp;
    };

    // p_display = A * p_uwb + t (2D)
    struct Affine
    {
        double a = 1, b = 0, c = 0;   // x' = a x + b y + c
        double d = 0, e = 1, f = 0;   // y' = d x + e y + f
        bool valid = false;           // fitted (else identity)
    };

    static std::string format(const godot::String& fmt, const std::string& robot);
    static bool match(const godot::String& fmt, const std::string& topic, std::string& robot);
    void add_robot(const std::string& r);
    void discover();
    void on_pose(const std::string& robot, const geometry_msgs::msg::PoseStamped& msg);
    void on_nav_markers(const std::string& robot, const visualization_msgs::msg::MarkerArray& msg);
    static void parse_anchors(const visualization_msgs::msg::MarkerArray& msg, std::map<int, Anchor>& out);
    void refit();
    void fit_axis();
    void to_display(double& x, double& y) const;
    void to_uwb(double& x, double& y) const;
    double yaw_to_display(double yaw) const;

    godot::PackedStringArray robots_;
    bool auto_discover_ = true;
    godot::String node_name_ = "robomaster_gui";
    godot::String frame_id_ = "world";
    godot::String pose_topic_format_ = "/uwb_ekf/{}/pose";
    godot::String cmd_topic_format_ = "/{}/cmd_vel";
    godot::String raw_pose_topic_format_ = "/uwb/{}/pose";
    double raw_timeout_ = 1.0;
    godot::String imu_topic_format_ = "/{}/odometry/filtered";
    godot::String anchors_topic_ = "/uwb/anchors";
    godot::String display_anchors_topic_;
    int origin_anchor_ = 0;
    int axis_anchor_ = 1;
    bool enu_ = false;
    double enu_theta_ = 0.0;
    double enu_h_ = -1.0;
    double floor_z_ = -1.75;   // = floor_z of linktrack.ekf.launch.py

    rclcpp::Context::SharedPtr context_;
    rclcpp::Node::SharedPtr node_;
    std::shared_ptr<rclcpp::executors::MultiThreadedExecutor> executor_;
    std::thread spin_thread_;
    std::vector<rclcpp::SubscriptionBase::SharedPtr> subs_;
    std::mutex subs_mutex_;
    std::set<std::string> known_robots_;   // reserved in add_robot (entity creation is slow)
    rclcpp::SubscriptionOptions sub_options_;
    rclcpp::TimerBase::SharedPtr discovery_timer_;
    rclcpp::CallbackGroup::SharedPtr discovery_group_;   // the node keeps only a weak_ptr
    rclcpp::Publisher<std_msgs::msg::String>::SharedPtr select_pub_;

    mutable std::mutex mutex_;
    std::map<std::string, Robot> state_;
    std::map<int, Anchor> anchors_;           // UWB frame
    std::map<int, Anchor> display_anchors_;   // display frame
    Affine map_;
    std::string fit_info_;
    uint64_t rx_count_ = 0;
    uint64_t tx_count_ = 0;
};

}  // namespace robomaster_gui
