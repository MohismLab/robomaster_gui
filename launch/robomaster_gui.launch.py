"""Cyberpunk RTS GUI for the UWB RoboMaster fleet.

  ros2 launch robomaster_gui_node robomaster_gui.launch.py
  ros2 launch robomaster_gui_node robomaster_gui.launch.py robots:=rm_0,rm_2 fullscreen:=true   (default: auto)

Needs the poses (/uwb_ekf/<robot>/pose, linktrack.ekf.launch.py) and, for move
orders, uwb_goal_nav.py per robot (uwb_fleet.launch.py).
"""

from launch import LaunchDescription
from launch.actions import DeclareLaunchArgument, OpaqueFunction
from launch.substitutions import LaunchConfiguration
from launch_ros.actions import Node


def gui(context):
    cfg = {k: LaunchConfiguration(k).perform(context)
           for k in ('robots', 'pose_topic', 'cmd_topic', 'anchors_topic', 'display_anchors_topic', 'origin_anchor',
                     'axis_anchor', 'floor_z', 'spacing', 'fullscreen')}
    args = ['--robots', cfg['robots'], '--pose-topic', cfg['pose_topic'], '--cmd-topic', cfg['cmd_topic'],
            '--anchors-topic', cfg['anchors_topic'], '--display-anchors-topic', cfg['display_anchors_topic'],
            '--origin-anchor', cfg['origin_anchor'], '--axis-anchor', cfg['axis_anchor'], '--floor-z', cfg['floor_z'],
            '--spacing', cfg['spacing']]
    if cfg['fullscreen'].lower() in ('1', 'true', 'yes'):
        args.append('--fullscreen')
    return [Node(package='robomaster_gui_node', executable='robomaster_gui', name='robomaster_gui',
                 arguments=args, output='screen')]


def generate_launch_description():
    return LaunchDescription([
        DeclareLaunchArgument('robots', default_value='auto',
                              description='auto: every robot seen in the pose topics (also new ones); or a list'),
        DeclareLaunchArgument('pose_topic', default_value='/uwb_ekf/{}/pose', description='{} = robot'),
        DeclareLaunchArgument('cmd_topic', default_value='/{}/cmd_vel', description='{} = robot'),
        DeclareLaunchArgument('anchors_topic', default_value='/uwb/anchors', description='anchors in the UWB frame'),
        DeclareLaunchArgument('origin_anchor', default_value='0', description='display frame origin'),
        DeclareLaunchArgument('axis_anchor', default_value='1', description='display frame +x points to this anchor'),
        DeclareLaunchArgument('floor_z', default_value='-1.75', description='floor height in the UWB frame'),
        DeclareLaunchArgument('display_anchors_topic', default_value='',
                              description='optional: show everything in the frame of these anchors instead '
                                          '(e.g. /uwb_viz/rm_0/anchors)'),
        DeclareLaunchArgument('spacing', default_value='0.5', description='formation spacing [m]'),
        DeclareLaunchArgument('fullscreen', default_value='false'),
        OpaqueFunction(function=gui),
    ])
