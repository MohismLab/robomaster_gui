"""Cyberpunk RTS GUI for the UWB RoboMaster fleet.

  ros2 launch robomaster_gui_node robomaster_gui.launch.py
  ros2 launch robomaster_gui_node robomaster_gui.launch.py robots:=rm_0,rm_2 fullscreen:=true   (default: auto)

Needs the poses (/uwb_ekf/<robot>/pose, linktrack.ekf.launch.py) and, for move
orders, uwb_goal_nav.py per robot (uwb_fleet.launch.py).
"""

import os

import yaml
from ament_index_python.packages import PackageNotFoundError, get_package_share_directory
from launch import LaunchDescription
from launch.actions import DeclareLaunchArgument, OpaqueFunction
from launch.substitutions import LaunchConfiguration
from launch_ros.actions import Node


def tag_names(path):
    """robot names of nlink_parser2's uwb_tags.yaml (tag id -> robot name), or None"""
    if not path:
        try:
            path = os.path.join(get_package_share_directory('nlink_parser2'), 'config', 'uwb_tags.yaml')
        except PackageNotFoundError:
            return None
    if not os.path.isfile(path):
        return None
    with open(path) as f:
        data = yaml.safe_load(f) or {}
    for params in data.values():
        names = (params or {}).get('ros__parameters', {}).get('tag_names')
        if names:
            return [str(n) for n in names]
    return None


def gui(context):
    cfg = {k: LaunchConfiguration(k).perform(context)
           for k in ('robots', 'pose_topic', 'cmd_topic', 'anchors_topic', 'display_anchors_topic', 'origin_anchor',
                     'axis_anchor', 'floor_z', 'spacing', 'fullscreen', 'tags_file', 'drive_kinds',
                     'cmd_domains')}
    # robots: the UWB tag mapping when there is one (only these tags are published, so
    # stray ids never show up as robots), otherwise discovered from the pose topics
    if cfg['robots'] == 'auto':
        names = tag_names(cfg['tags_file'])
        if names:
            cfg['robots'] = ','.join(names)
            print(f'[robomaster_gui] robots from uwb_tags.yaml: {cfg["robots"]}')
    args = ['--robots', cfg['robots'], '--pose-topic', cfg['pose_topic'], '--cmd-topic', cfg['cmd_topic'],
            '--anchors-topic', cfg['anchors_topic'], '--display-anchors-topic', cfg['display_anchors_topic'],
            '--origin-anchor', cfg['origin_anchor'], '--axis-anchor', cfg['axis_anchor'], '--floor-z', cfg['floor_z'],
            '--spacing', cfg['spacing'], '--drive-kinds', cfg['drive_kinds'], '--cmd-domains', cfg['cmd_domains']]
    if cfg['fullscreen'].lower() in ('1', 'true', 'yes'):
        args.append('--fullscreen')
    return [Node(package='robomaster_gui_node', executable='robomaster_gui', name='robomaster_gui',
                 arguments=args, output='screen')]


def generate_launch_description():
    return LaunchDescription([
        DeclareLaunchArgument('robots', default_value='auto',
                              description='auto: tag_names of uwb_tags.yaml, else every robot seen in the pose '
                                          'topics (also new ones); or a list'),
        DeclareLaunchArgument('tags_file', default_value='',
                              description='UWB tag mapping (default: nlink_parser2/config/uwb_tags.yaml)'),
        DeclareLaunchArgument('drive_kinds', default_value='rm,dog',
                              description='robot kinds driven with cmd_vel (e.g. rm,dog / all); others are view only'),
        DeclareLaunchArgument('cmd_domains', default_value='dog=78',
                              description='DDS domain of a kind\'s cmd_vel, e.g. dog=78 (Go2 go2_sport_bridge)'),
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
