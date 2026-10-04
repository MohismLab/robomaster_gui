#include "ros_bridge.h"

#include <algorithm>
#include <cctype>
#include <cmath>

#include <godot_cpp/classes/engine.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/utility_functions.hpp>
#include <godot_cpp/variant/vector3.hpp>

using godot::Array;
using godot::ClassDB;
using godot::D_METHOD;
using godot::Dictionary;
using godot::PackedStringArray;
using godot::PropertyInfo;
using godot::String;
using godot::UtilityFunctions;
using godot::Variant;
using godot::Vector3;

namespace robomaster_gui
{

namespace
{
std::string to_std(const String& s)
{
    return std::string(s.utf8().get_data());
}

double seconds_since(std::chrono::steady_clock::time_point t)
{
    return std::chrono::duration<double>(std::chrono::steady_clock::now() - t).count();
}
}  // namespace

RosBridge::~RosBridge()
{
    stop();
}

void RosBridge::_bind_methods()
{
    ClassDB::bind_method(D_METHOD("start"), &RosBridge::start);
    ClassDB::bind_method(D_METHOD("stop"), &RosBridge::stop);
    ClassDB::bind_method(D_METHOD("is_running"), &RosBridge::is_running);
    ClassDB::bind_method(D_METHOD("get_robot_states"), &RosBridge::get_robot_states);
    ClassDB::bind_method(D_METHOD("get_anchors"), &RosBridge::get_anchors);
    ClassDB::bind_method(D_METHOD("get_stats"), &RosBridge::get_stats);
    ClassDB::bind_method(D_METHOD("send_goal", "robot", "x", "y", "yaw"), &RosBridge::send_goal);
    ClassDB::bind_method(D_METHOD("send_goal_3d", "robot", "x", "y", "height"), &RosBridge::send_goal_3d);
    ClassDB::bind_method(D_METHOD("cancel_goal", "robot"), &RosBridge::cancel_goal);
    ClassDB::bind_method(D_METHOD("send_cmd_vel", "robot", "vx", "vy", "wz"), &RosBridge::send_cmd_vel);
    ClassDB::bind_method(D_METHOD("publish_selection", "robots"), &RosBridge::publish_selection);
    ClassDB::bind_method(D_METHOD("get_frame_info"), &RosBridge::get_frame_info);
    ClassDB::bind_method(D_METHOD("to_uwb_xy", "display"), &RosBridge::to_uwb_xy);
    ClassDB::bind_method(D_METHOD("to_display_xy", "uwb"), &RosBridge::to_display_xy);
    ClassDB::bind_method(D_METHOD("is_frame_ready"), &RosBridge::is_frame_ready);
    ClassDB::bind_method(D_METHOD("set_enu_rotation", "theta", "handedness"), &RosBridge::set_enu_rotation);
    ClassDB::bind_method(D_METHOD("clear_enu_rotation"), &RosBridge::clear_enu_rotation);
    ClassDB::bind_method(D_METHOD("is_enu"), &RosBridge::is_enu);

#define RG_PROPERTY(name, type)                                                              \
    ClassDB::bind_method(D_METHOD("set_" #name, "value"), &RosBridge::set_##name);           \
    ClassDB::bind_method(D_METHOD("get_" #name), &RosBridge::get_##name);                    \
    ADD_PROPERTY(PropertyInfo(Variant::type, #name), "set_" #name, "get_" #name)

    RG_PROPERTY(robots, PACKED_STRING_ARRAY);
    RG_PROPERTY(auto_discover, BOOL);
    RG_PROPERTY(node_name, STRING);
    RG_PROPERTY(frame_id, STRING);
    RG_PROPERTY(pose_topic_format, STRING);
    RG_PROPERTY(cmd_topic_format, STRING);
    RG_PROPERTY(cmd_domains, STRING);
    RG_PROPERTY(raw_pose_topic_format, STRING);
    RG_PROPERTY(raw_timeout, FLOAT);
    RG_PROPERTY(imu_topic_format, STRING);
    RG_PROPERTY(anchors_topic, STRING);
    RG_PROPERTY(display_anchors_topic, STRING);
    RG_PROPERTY(origin_anchor, INT);
    RG_PROPERTY(axis_anchor, INT);
    RG_PROPERTY(floor_z, FLOAT);
#undef RG_PROPERTY
}

std::string RosBridge::format(const String& fmt, const std::string& robot)
{
    std::string s = to_std(fmt);
    auto pos = s.find("{}");
    if (pos != std::string::npos)
    {
        s.replace(pos, 2, robot);
    }
    return s;
}

void RosBridge::add_robot(const std::string& r)
{
    std::lock_guard<std::mutex> subs_lock(subs_mutex_);
    if (!known_robots_.insert(r).second)
    {
        return;   // already added (or being added)
    }
    auto sensor_qos = rclcpp::SensorDataQoS();
    Robot robot;
    robot.goal_pub = node_->create_publisher<geometry_msgs::msg::PoseStamped>("/uwb_nav/" + r + "/goal_pose", 10);
    robot.cancel_pub = node_->create_publisher<std_msgs::msg::Empty>("/uwb_nav/" + r + "/cancel", 10);
    int domain = cmd_domain_of(r);
    auto cmd_node = domain >= 0 ? domain_node(domain) : node_;
    robot.cmd_pub = cmd_node->create_publisher<geometry_msgs::msg::Twist>(format(cmd_topic_format_, r), 10);
    if (domain >= 0)
    {
        RCLCPP_INFO(node_->get_logger(), "%s: cmd_vel on DDS domain %d", r.c_str(), domain);
    }
    {
        std::lock_guard<std::mutex> lock(mutex_);
        state_[r] = robot;
    }
    subs_.push_back(node_->create_subscription<geometry_msgs::msg::PoseStamped>(
        format(pose_topic_format_, r), sensor_qos,
        [this, r](geometry_msgs::msg::PoseStamped::ConstSharedPtr msg) { on_pose(r, *msg); }, sub_options_));
    if (!raw_pose_topic_format_.is_empty())
    {
        subs_.push_back(node_->create_subscription<geometry_msgs::msg::PoseStamped>(
            format(raw_pose_topic_format_, r), sensor_qos,
            [this, r](geometry_msgs::msg::PoseStamped::ConstSharedPtr msg) {
                std::lock_guard<std::mutex> lock(mutex_);
                auto it = state_.find(r);
                if (it != state_.end())
                {
                    it->second.has_raw = true;
                    it->second.raw_z = msg->pose.position.z;
                    it->second.raw_stamp = Clock::now();
                }
            },
            sub_options_));
    }
    if (!imu_topic_format_.is_empty())
    {
        subs_.push_back(node_->create_subscription<nav_msgs::msg::Odometry>(
            format(imu_topic_format_, r), sensor_qos,
            [this, r](nav_msgs::msg::Odometry::ConstSharedPtr msg) {
                const auto& q = msg->pose.pose.orientation;
                double yaw = std::atan2(2.0 * (q.w * q.z + q.x * q.y), 1.0 - 2.0 * (q.y * q.y + q.z * q.z));
                std::lock_guard<std::mutex> lock(mutex_);
                auto it = state_.find(r);
                if (it != state_.end() && std::isfinite(yaw))
                {
                    it->second.has_imu = true;
                    it->second.imu_yaw = yaw;
                    it->second.imu_stamp = Clock::now();
                }
                ++rx_count_;
            },
            sub_options_));
        subs_.push_back(node_->create_subscription<std_msgs::msg::String>(
            "/" + r + "/imu/flat_calib/status", rclcpp::QoS(1).reliable().transient_local(),
            [this, r](std_msgs::msg::String::ConstSharedPtr msg) {
                std::lock_guard<std::mutex> lock(mutex_);
                auto it = state_.find(r);
                if (it != state_.end())
                {
                    it->second.calib_status = msg->data;
                    it->second.calib_stamp = Clock::now();
                }
            },
            sub_options_));
        subs_.push_back(node_->create_subscription<std_msgs::msg::String>(
            "/" + r + "/imu/mag_state", 10,
            [this, r](std_msgs::msg::String::ConstSharedPtr msg) {
                std::lock_guard<std::mutex> lock(mutex_);
                auto it = state_.find(r);
                if (it != state_.end())
                {
                    it->second.mag_state = msg->data;
                }
            },
            sub_options_));
    }
    subs_.push_back(node_->create_subscription<std_msgs::msg::Bool>(
        "/uwb_ekf/" + r + "/pose_valid", rclcpp::QoS(1).reliable().transient_local(),
        [this, r](std_msgs::msg::Bool::ConstSharedPtr msg) {
            std::lock_guard<std::mutex> lock(mutex_);
            auto it = state_.find(r);
            if (it != state_.end())
            {
                if (it->second.pose_valid && !msg->data)
                {
                    it->second.invalid_stamp = Clock::now();
                }
                it->second.pose_valid = msg->data;
                it->second.pose_valid_seen = true;
            }
        },
        sub_options_));
    subs_.push_back(node_->create_subscription<std_msgs::msg::Bool>(
        "/uwb_ekf/" + r + "/heading_valid", rclcpp::QoS(1).reliable().transient_local(),
        [this, r](std_msgs::msg::Bool::ConstSharedPtr msg) {
            std::lock_guard<std::mutex> lock(mutex_);
            auto it = state_.find(r);
            if (it != state_.end())
            {
                it->second.heading_valid = msg->data;
            }
        },
        sub_options_));
    subs_.push_back(node_->create_subscription<visualization_msgs::msg::MarkerArray>(
        "/uwb_nav/" + r + "/markers", 10,
        [this, r](visualization_msgs::msg::MarkerArray::ConstSharedPtr msg) { on_nav_markers(r, *msg); }, sub_options_));
    RCLCPP_INFO(node_->get_logger(), "robot %s added", r.c_str());
}

int RosBridge::cmd_domain_of(const std::string& robot) const
{
    // kind prefix of "<prefix>_<id>"
    std::string prefix = robot;
    auto k = robot.rfind('_');
    if (k != std::string::npos && k + 1 < robot.size() &&
        std::all_of(robot.begin() + k + 1, robot.end(), [](char c) { return std::isdigit(static_cast<unsigned char>(c)); }))
    {
        prefix = robot.substr(0, k);
    }
    // "dog=78,fly=5"
    std::string spec = to_std(cmd_domains_);
    size_t pos = 0;
    while (pos < spec.size())
    {
        size_t end = spec.find(',', pos);
        std::string item = spec.substr(pos, end == std::string::npos ? std::string::npos : end - pos);
        auto eq = item.find('=');
        if (eq != std::string::npos && item.substr(0, eq) == prefix)
        {
            try
            {
                return std::stoi(item.substr(eq + 1));
            }
            catch (const std::exception&)
            {
                return -1;
            }
        }
        if (end == std::string::npos)
        {
            break;
        }
        pos = end + 1;
    }
    return -1;
}

rclcpp::Node::SharedPtr RosBridge::domain_node(int domain)
{
    // called with subs_mutex_ held
    auto it = domain_nodes_.find(domain);
    if (it != domain_nodes_.end())
    {
        return it->second.second;
    }
    auto ctx = std::make_shared<rclcpp::Context>();
    rclcpp::InitOptions opts;
    opts.shutdown_on_signal = false;
    opts.set_domain_id(static_cast<size_t>(domain));
    ctx->init(0, nullptr, opts);
    rclcpp::NodeOptions node_options;
    node_options.context(ctx);
    auto node = std::make_shared<rclcpp::Node>(to_std(node_name_) + "_d" + std::to_string(domain), node_options);
    domain_nodes_[domain] = {ctx, node};
    return node;
}

bool RosBridge::match(const String& fmt, const std::string& topic, std::string& robot)
{
    std::string f = to_std(fmt);
    auto pos = f.find("{}");
    if (pos == std::string::npos)
    {
        return false;
    }
    std::string pre = f.substr(0, pos), post = f.substr(pos + 2);
    if (topic.size() <= pre.size() + post.size() || topic.compare(0, pre.size(), pre) != 0 ||
        topic.compare(topic.size() - post.size(), post.size(), post) != 0)
    {
        return false;
    }
    robot = topic.substr(pre.size(), topic.size() - pre.size() - post.size());
    for (char c : robot)
    {
        if (!(std::isalnum(static_cast<unsigned char>(c)) || c == '_'))
        {
            return false;
        }
    }
    return !robot.empty();
}

void RosBridge::discover()
{
    for (const auto& [topic, types] : node_->get_topic_names_and_types())
    {
        std::string r;
        if (match(pose_topic_format_, topic, r) || (!raw_pose_topic_format_.is_empty() && match(raw_pose_topic_format_, topic, r)))
        {
            add_robot(r);
        }
    }
}

bool RosBridge::start()
{
    if (godot::Engine::get_singleton()->is_editor_hint() || is_running())
    {
        return is_running();
    }
    try
    {
        // private context, no signal handlers: Ctrl+C / window close belong to Godot
        context_ = std::make_shared<rclcpp::Context>();
        rclcpp::InitOptions init_options;
        init_options.shutdown_on_signal = false;
        context_->init(0, nullptr, init_options);

        rclcpp::NodeOptions node_options;
        node_options.context(context_);
        node_ = std::make_shared<rclcpp::Node>(to_std(node_name_), node_options);

        rclcpp::ExecutorOptions exec_options;
        exec_options.context = context_;
        // pose / marker callbacks of the robots run in parallel, state is guarded by mutex_
        executor_ = std::make_shared<rclcpp::executors::MultiThreadedExecutor>(exec_options, 4);

        sub_options_ = rclcpp::SubscriptionOptions();
        sub_options_.callback_group = node_->create_callback_group(rclcpp::CallbackGroupType::Reentrant);
        auto sub_options = sub_options_;
        for (int i = 0; i < robots_.size(); ++i)
        {
            add_robot(to_std(robots_[i]));
        }
        if (auto_discover_)
        {
            // own mutually exclusive group: a slow scan never overlaps the next one
            discovery_group_ = node_->create_callback_group(rclcpp::CallbackGroupType::MutuallyExclusive);
            discovery_timer_ = node_->create_wall_timer(std::chrono::seconds(2), [this] { discover(); }, discovery_group_);
        }
        // every subscription gets its own reentrant group so the executor threads can serve them concurrently
        subs_.push_back(node_->create_subscription<visualization_msgs::msg::MarkerArray>(
            to_std(anchors_topic_), 10, [this](visualization_msgs::msg::MarkerArray::ConstSharedPtr msg) {
                std::lock_guard<std::mutex> lock(mutex_);
                parse_anchors(*msg, anchors_);
                refit();
                ++rx_count_;
            }, sub_options));
        if (!display_anchors_topic_.is_empty())
        {
            subs_.push_back(node_->create_subscription<visualization_msgs::msg::MarkerArray>(
                to_std(display_anchors_topic_), 10, [this](visualization_msgs::msg::MarkerArray::ConstSharedPtr msg) {
                    std::lock_guard<std::mutex> lock(mutex_);
                    parse_anchors(*msg, display_anchors_);
                    refit();
                    ++rx_count_;
                }, sub_options));
        }
        select_pub_ = node_->create_publisher<std_msgs::msg::String>("/uwb_nav/select", 10);

        executor_->add_node(node_);
        spin_thread_ = std::thread([exec = executor_] { exec->spin(); });
        UtilityFunctions::print("[robomaster_gui] ROS 2 node /", node_name_, " up, robots: ",
                                robots_.size() ? String(",").join(robots_) : String("-"),
                                auto_discover_ ? " + auto discovery" : "");
        return true;
    }
    catch (const std::exception& e)
    {
        UtilityFunctions::push_error("[robomaster_gui] ROS start failed: ", e.what());
        stop();
        return false;
    }
}

void RosBridge::stop()
{
    if (executor_)
    {
        executor_->cancel();
    }
    if (spin_thread_.joinable())
    {
        spin_thread_.join();
    }
    discovery_timer_.reset();
    discovery_group_.reset();
    {
        std::lock_guard<std::mutex> lock(subs_mutex_);
        subs_.clear();
        known_robots_.clear();
    }
    {
        std::lock_guard<std::mutex> lock(mutex_);
        state_.clear();   // drops the publishers before their nodes go
    }
    for (auto& [domain, cn] : domain_nodes_)
    {
        cn.second.reset();
        if (cn.first && cn.first->is_valid())
        {
            cn.first->shutdown("robomaster_gui stop");
        }
    }
    domain_nodes_.clear();
    select_pub_.reset();
    {
        std::lock_guard<std::mutex> lock(mutex_);
        state_.clear();
        anchors_.clear();
        display_anchors_.clear();
        map_ = Affine();
    }
    executor_.reset();
    node_.reset();
    if (context_ && context_->is_valid())
    {
        context_->shutdown("robomaster_gui stop");
    }
    context_.reset();
}

bool RosBridge::is_running() const
{
    return node_ != nullptr && spin_thread_.joinable();
}

void RosBridge::on_pose(const std::string& robot, const geometry_msgs::msg::PoseStamped& msg)
{
    const auto& q = msg.pose.orientation;
    double yaw = std::atan2(2.0 * (q.w * q.z + q.x * q.y), 1.0 - 2.0 * (q.y * q.y + q.z * q.z));
    std::lock_guard<std::mutex> lock(mutex_);
    auto it = state_.find(robot);
    if (it == state_.end())
    {
        return;
    }
    Robot& r = it->second;
    // tag silent (power loss): the EKF only extrapolates, keep the last trusted pose
    if (!r.pose_valid || (!r.pose_valid_seen && !raw_pose_topic_format_.is_empty() &&
                          (!r.has_raw || seconds_since(r.raw_stamp) > raw_timeout_)))
    {
        return;
    }
    r.has_pose = true;
    r.x = msg.pose.position.x;
    r.y = msg.pose.position.y;
    r.z = msg.pose.position.z;
    r.yaw = std::isfinite(yaw) ? yaw : 0.0;
    r.stamp = Clock::now();
    ++r.seq;
    ++rx_count_;
}

void RosBridge::on_nav_markers(const std::string& robot, const visualization_msgs::msg::MarkerArray& msg)
{
    // uwb_goal_nav.py: ns uwb_nav, id 0 goal disc, id 1 line, id 2 status text
    std::lock_guard<std::mutex> lock(mutex_);
    auto it = state_.find(robot);
    if (it == state_.end())
    {
        return;
    }
    Robot& r = it->second;
    for (const auto& m : msg.markers)
    {
        if (m.ns != "uwb_nav")
        {
            continue;
        }
        bool add = m.action == visualization_msgs::msg::Marker::ADD;
        if (m.id == 0)
        {
            r.has_goal = add;
            r.gx = m.pose.position.x;
            r.gy = m.pose.position.y;
        }
        else if (m.id == 2)
        {
            r.status = add ? m.text : "";
        }
    }
    ++rx_count_;
}

void RosBridge::parse_anchors(const visualization_msgs::msg::MarkerArray& msg, std::map<int, Anchor>& out)
{
    auto now = Clock::now();
    for (const auto& m : msg.markers)
    {
        if (m.type == visualization_msgs::msg::Marker::TEXT_VIEW_FACING ||
            m.action != visualization_msgs::msg::Marker::ADD)
        {
            continue;
        }
        // linktrack_node / uwb_mocap_viz: model id = 2 * anchor id, label id = 2 * anchor id + 1
        int id = m.ns == "uwb_anchors" ? m.id / 2 : m.id;
        out[id] = {m.pose.position.x, m.pose.position.y, m.pose.position.z, now};
    }
}

void RosBridge::fit_axis()
{
    // origin at A<origin_anchor_>, +x towards A<axis_anchor_> (mutex_ held)
    auto o = anchors_.find(origin_anchor_);
    auto x = anchors_.find(axis_anchor_);
    if (o == anchors_.end() || x == anchors_.end())
    {
        map_.valid = false;
        return;
    }
    double x0 = o->second.x, y0 = o->second.y;
    bool was_valid = map_.valid;
    char buf[160];
    if (enu_)
    {
        // ENU yaw = h (psi - theta): rows [c s; -h s, h c] applied to (p - A0)
        double c = std::cos(enu_theta_), s = std::sin(enu_theta_), h = enu_h_;
        map_ = {c, s, -(c * x0 + s * y0), -h * s, h * c, -(-h * s * x0 + h * c * y0), true};
        std::snprintf(buf, sizeof(buf), "ENU, origin A%d (UWB x-axis at %.1f deg from magnetic east%s)", origin_anchor_,
                      -h * enu_theta_ * 180.0 / M_PI, h < 0 ? ", mirrored" : "");
    }
    else
    {
        double th = std::atan2(x->second.y - o->second.y, x->second.x - o->second.x);
        double c = std::cos(th), s = std::sin(th);
        // p' = R(-th) (p - A0)
        map_ = {c, s, -(c * x0 + s * y0), -s, c, s * x0 - c * y0, true};
        std::snprintf(buf, sizeof(buf), "origin A%d, +x -> A%d (UWB heading %.1f deg)", origin_anchor_, axis_anchor_,
                      th * 180.0 / M_PI);
    }
    if (!was_valid || fit_info_ != buf)
    {
        RCLCPP_INFO(node_->get_logger(), "display frame: %s", buf);
    }
    fit_info_ = buf;
}

void RosBridge::set_enu_rotation(double theta, double handedness)
{
    std::lock_guard<std::mutex> lock(mutex_);
    enu_ = true;
    enu_theta_ = theta;
    enu_h_ = handedness < 0 ? -1.0 : 1.0;
    if (display_anchors_topic_.is_empty())
    {
        fit_axis();
    }
}

void RosBridge::clear_enu_rotation()
{
    std::lock_guard<std::mutex> lock(mutex_);
    enu_ = false;
    if (display_anchors_topic_.is_empty())
    {
        fit_axis();
    }
}

bool RosBridge::is_enu() const
{
    std::lock_guard<std::mutex> lock(mutex_);
    return enu_ && map_.valid && display_anchors_topic_.is_empty();
}

void RosBridge::refit()
{
    if (display_anchors_topic_.is_empty())
    {
        fit_axis();
        return;
    }
    // least squares affine map over the anchors known in both frames (mutex_ held)
    double sxx = 0, sxy = 0, syy = 0, sx = 0, sy = 0, n = 0;
    double bx[3] = {0, 0, 0}, by[3] = {0, 0, 0};
    for (const auto& [id, u] : anchors_)
    {
        auto it = display_anchors_.find(id);
        if (it == display_anchors_.end())
        {
            continue;
        }
        const Anchor& d = it->second;
        sxx += u.x * u.x; sxy += u.x * u.y; syy += u.y * u.y; sx += u.x; sy += u.y; n += 1;
        bx[0] += u.x * d.x; bx[1] += u.y * d.x; bx[2] += d.x;
        by[0] += u.x * d.y; by[1] += u.y * d.y; by[2] += d.y;
    }
    if (n < 3)
    {
        map_.valid = false;
        return;
    }
    // normal matrix [[sxx sxy sx] [sxy syy sy] [sx sy n]], solved by Cramer's rule
    double m[3][3] = {{sxx, sxy, sx}, {sxy, syy, sy}, {sx, sy, n}};
    auto det3 = [](const double a[3][3]) {
        return a[0][0] * (a[1][1] * a[2][2] - a[1][2] * a[2][1]) - a[0][1] * (a[1][0] * a[2][2] - a[1][2] * a[2][0]) +
               a[0][2] * (a[1][0] * a[2][1] - a[1][1] * a[2][0]);
    };
    double det = det3(m);
    if (std::abs(det) < 1e-9)
    {
        map_.valid = false;  // anchors collinear
        return;
    }
    auto solve = [&](const double b[3], double out[3]) {
        for (int k = 0; k < 3; ++k)
        {
            double mk[3][3];
            for (int r = 0; r < 3; ++r)
            {
                for (int c = 0; c < 3; ++c)
                {
                    mk[r][c] = c == k ? b[r] : m[r][c];
                }
            }
            out[k] = det3(mk) / det;
        }
    };
    double px[3], py[3];
    solve(bx, px);
    solve(by, py);
    bool was_valid = map_.valid;
    map_ = {px[0], px[1], px[2], py[0], py[1], py[2], true};
    double lin = map_.a * map_.e - map_.b * map_.d;
    char buf[160];
    std::snprintf(buf, sizeof(buf), "UWB->display: rot %.1f deg, scale %.3f%s, %d anchors",
                  std::atan2(map_.d, map_.a) * 180.0 / M_PI, std::sqrt(std::abs(lin)), lin < 0 ? ", mirrored" : "",
                  static_cast<int>(n));
    fit_info_ = buf;
    if (!was_valid)
    {
        RCLCPP_INFO(node_->get_logger(), "%s", fit_info_.c_str());
    }
}

void RosBridge::to_display(double& x, double& y) const
{
    if (!map_.valid)
    {
        return;
    }
    double nx = map_.a * x + map_.b * y + map_.c;
    double ny = map_.d * x + map_.e * y + map_.f;
    x = nx;
    y = ny;
}

void RosBridge::to_uwb(double& x, double& y) const
{
    if (!map_.valid)
    {
        return;
    }
    double det = map_.a * map_.e - map_.b * map_.d;
    double dx = x - map_.c, dy = y - map_.f;
    x = (map_.e * dx - map_.b * dy) / det;
    y = (-map_.d * dx + map_.a * dy) / det;
}

double RosBridge::yaw_to_display(double yaw) const
{
    if (!map_.valid)
    {
        return yaw;
    }
    double cx = std::cos(yaw), cy = std::sin(yaw);
    return std::atan2(map_.d * cx + map_.e * cy, map_.a * cx + map_.b * cy);
}

godot::Vector2 RosBridge::to_uwb_xy(const godot::Vector2& display) const
{
    std::lock_guard<std::mutex> lock(mutex_);
    double x = display.x, y = display.y;
    to_uwb(x, y);
    return godot::Vector2(x, y);
}

godot::Vector2 RosBridge::to_display_xy(const godot::Vector2& uwb) const
{
    std::lock_guard<std::mutex> lock(mutex_);
    double x = uwb.x, y = uwb.y;
    to_display(x, y);
    return godot::Vector2(x, y);
}

bool RosBridge::is_frame_ready() const
{
    std::lock_guard<std::mutex> lock(mutex_);
    return map_.valid;
}

String RosBridge::get_frame_info() const
{
    std::lock_guard<std::mutex> lock(mutex_);
    if (!map_.valid)
    {
        return "UWB frame (waiting for anchors)";
    }
    return String::utf8(fit_info_.c_str());
}

Dictionary RosBridge::get_robot_states() const
{
    Dictionary out;
    std::lock_guard<std::mutex> lock(mutex_);
    for (const auto& [name, r] : state_)
    {
        double x = r.x, y = r.y, gx = r.gx, gy = r.gy;
        to_display(x, y);
        to_display(gx, gy);
        Dictionary d;
        d["has_pose"] = r.has_pose;
        d["position"] = Vector3(x, y, r.z);
        d["yaw"] = yaw_to_display(r.yaw);
        // signal age: the older of the EKF pose and the raw UWB pose
        double age = r.has_pose ? seconds_since(r.stamp) : 1e9;
        if (!raw_pose_topic_format_.is_empty() && !r.pose_valid_seen)
        {
            age = std::max(age, r.has_raw ? seconds_since(r.raw_stamp) : 1e9);
        }
        if (!r.pose_valid)
        {
            // declared invalid by the adapter: lost right away, age counts from then on
            age = std::max(age, raw_timeout_ + seconds_since(r.invalid_stamp));
        }
        d["age"] = age;
        d["pose_valid"] = r.pose_valid;
        // height above the floor from the raw UWB z (the EKF pins z to the floor)
        d["height"] = r.has_raw ? r.raw_z - floor_z_ : 0.0;
        d["has_goal"] = r.has_goal;
        d["goal"] = Vector3(gx, gy, 0.0);
        d["status"] = String::utf8(r.status.c_str());
        // raw UWB frame values, for the navigation running in Godot
        d["uwb_position"] = godot::Vector2(r.x, r.y);
        d["uwb_yaw"] = r.yaw;
        d["has_orientation"] = r.heading_valid;
        d["seq"] = static_cast<int64_t>(r.seq);
        d["t"] = std::chrono::duration<double>(r.stamp - t0_).count();
        d["has_imu"] = r.has_imu;
        d["imu_yaw"] = r.imu_yaw;
        d["imu_age"] = r.has_imu ? seconds_since(r.imu_stamp) : 1e9;
        d["mag_state"] = String::utf8(r.mag_state.c_str());
        // the calibration republishes about every second; a stale latched "calibrating"
        // (calibration process killed) expires after 3 s
        d["calib_status"] = String::utf8(r.calib_status.c_str());
        d["calibrating"] = r.calib_status.rfind("校准中", 0) == 0 && seconds_since(r.calib_stamp) < 3.0;
        out[String::utf8(name.c_str())] = d;
    }
    return out;
}

Array RosBridge::get_anchors() const
{
    Array out;
    std::lock_guard<std::mutex> lock(mutex_);
    bool external = !display_anchors_topic_.is_empty() && !display_anchors_.empty();
    const auto& src = external ? display_anchors_ : anchors_;
    for (const auto& [id, a] : src)
    {
        double x = a.x, y = a.y, z = a.z;
        if (!external)
        {
            to_display(x, y);
            z -= floor_z_;
        }
        Dictionary d;
        d["id"] = id;
        d["position"] = Vector3(x, y, z);
        d["age"] = seconds_since(a.stamp);
        out.push_back(d);
    }
    return out;
}

Dictionary RosBridge::get_stats() const
{
    Dictionary d;
    std::lock_guard<std::mutex> lock(mutex_);
    d["rx"] = static_cast<int64_t>(rx_count_);
    d["tx"] = static_cast<int64_t>(tx_count_);
    d["running"] = node_ != nullptr;
    return d;
}

void RosBridge::send_goal(const String& robot, double x, double y, double yaw)
{
    std::lock_guard<std::mutex> lock(mutex_);
    auto it = state_.find(to_std(robot));
    if (!node_ || it == state_.end())
    {
        return;
    }
    // x, y are display coordinates, the navigator works in the UWB frame
    to_uwb(x, y);
    geometry_msgs::msg::PoseStamped msg;
    msg.header.stamp = node_->now();
    msg.header.frame_id = to_std(frame_id_);
    msg.pose.position.x = x;
    msg.pose.position.y = y;
    msg.pose.orientation.z = std::sin(yaw / 2.0);
    msg.pose.orientation.w = std::cos(yaw / 2.0);
    it->second.goal_pub->publish(msg);
    ++tx_count_;
}

void RosBridge::send_goal_3d(const String& robot, double x, double y, double height)
{
    std::lock_guard<std::mutex> lock(mutex_);
    auto it = state_.find(to_std(robot));
    if (!node_ || it == state_.end())
    {
        return;
    }
    // display x, y and the height above the floor -> UWB frame
    to_uwb(x, y);
    geometry_msgs::msg::PoseStamped msg;
    msg.header.stamp = node_->now();
    msg.header.frame_id = to_std(frame_id_);
    msg.pose.position.x = x;
    msg.pose.position.y = y;
    msg.pose.position.z = height + floor_z_;
    msg.pose.orientation.w = 1.0;
    it->second.goal_pub->publish(msg);
    ++tx_count_;
}

void RosBridge::cancel_goal(const String& robot)
{
    std::lock_guard<std::mutex> lock(mutex_);
    auto it = state_.find(to_std(robot));
    if (!node_ || it == state_.end())
    {
        return;
    }
    it->second.cancel_pub->publish(std_msgs::msg::Empty());
    ++tx_count_;
}

void RosBridge::send_cmd_vel(const String& robot, double vx, double vy, double wz)
{
    std::lock_guard<std::mutex> lock(mutex_);
    auto it = state_.find(to_std(robot));
    if (!node_ || it == state_.end())
    {
        return;
    }
    geometry_msgs::msg::Twist msg;
    msg.linear.x = vx;
    msg.linear.y = vy;
    msg.angular.z = wz;
    it->second.cmd_pub->publish(msg);
    ++tx_count_;
}

void RosBridge::publish_selection(const PackedStringArray& robots)
{
    if (!select_pub_)
    {
        return;
    }
    std_msgs::msg::String msg;
    msg.data = to_std(String(",").join(robots));
    select_pub_->publish(msg);
    std::lock_guard<std::mutex> lock(mutex_);
    ++tx_count_;
}

}  // namespace robomaster_gui
