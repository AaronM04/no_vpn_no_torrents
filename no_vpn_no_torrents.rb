#!/usr/bin/env ruby

# This script will suspend your torrent client if a specific VPN connection is
# disabled, and resume the torrent client when the VPN is enabled. A sound is
# played periodically while the torrent client is suspended (TODO). Please edit the
# constants below for configuration.

require 'dbus'
require 'pp'
require 'thread'

CONNECTION_ID = "tun0" # OLD: "ipvanish-US-New-York-nyc-a01"
TORRENT_CLIENT = 'transmission-gtk'
ALARM_COMMAND = 'mpv'
ALARM_SOUND = '/usr/lib64/libreoffice/share/gallery/sounds/laser.wav'

def pause_torrents
  `kill -STOP $(pidof #{TORRENT_CLIENT})`
end

def continue_torrents
  `kill -CONT $(pidof #{TORRENT_CLIENT})`
end

@alarm_mutex = Mutex.new
def alarm
  return if @alarm_mutex.locked?     # try to avoid stacking up of alarms
  Thread.new do
    @alarm_mutex.synchronize { `#{ALARM_COMMAND} #{ALARM_SOUND}` }
  end
end


def get_active_settings(nm_service, active_conn_paths, settings)
  active_paths = []
  active_conn_paths.each do |ac_path|
    ac_obj = nm_service.object(ac_path)
    ac_iface = ac_obj['org.freedesktop.NetworkManager.Connection.Active']
    begin
      active_paths.push(ac_iface['Connection']) if ac_iface
    rescue DBus::Error
      next
    end
  end
  settings.select{|setting| active_paths.include?(setting.path) }
end



def on_vpn(nm_service, nm_iface)
  settings = Setting.get_settings(nm_service)
  active_conn_paths = nm_iface['ActiveConnections']
  active_settings = get_active_settings(nm_service, active_conn_paths, settings)
  active_settings.count{|s| s.id == CONNECTION_ID } > 0
end

# Connectivity states: https://developer.gnome.org/NetworkManager/unstable/nm-dbus-types.html#NMConnectivityState
def take_action
  if @connectivity >= 2 && !@connected_to_vpn
    puts "#{Time.now} Pausing"
    pause_torrents
    alarm
  else
    puts "#{Time.now} Continuing"
    continue_torrents
  end
end

class Setting
  attr_accessor :id, :n, :path, :type, :settings

  def self.get_settings(nm_service)
    if !nm_service.is_a? DBus::Service
      raise "expected DBus::Service (from system bus for org.freedesktop.NetworkManager)"
    end
    settings_obj = nm_service.object('/org/freedesktop/NetworkManager/Settings')
    settings_iface = settings_obj['org.freedesktop.NetworkManager.Settings']
    conn_paths = settings_iface.ListConnections.first
    settings = []
    conn_paths.map do |conn_path|
      conn_object = nm_service.object(conn_path)
      conn_iface = conn_object['org.freedesktop.NetworkManager.Settings.Connection']
      #puts "Setting #{n}: #{conn_iface.GetSettings}\n\n"
      Setting.new(conn_path, conn_iface.GetSettings.first)
    end
  end

  def initialize(path, settings)
    # path is like "/org/freedesktop/NetworkManager/Settings/N"
    path      =~ /\/(\d+)\z/
    @n         = $1.to_i
    @path      = path
    @settings  = settings
    @id        = settings['connection']['id']
    @type      = settings['connection']['type']
  end
end

bus = DBus.system_bus
nm_service = bus.service('org.freedesktop.NetworkManager')


nm_obj   = nm_service.object('/org/freedesktop/NetworkManager')
nm_iface = nm_obj['org.freedesktop.NetworkManager']

@connectivity = nm_iface['Connectivity']
active_conn_paths = nm_iface['ActiveConnections']
@connected_to_vpn = on_vpn(nm_service, nm_iface)
take_action

nm_iface.on_signal('PropertiesChanged') do |changed|
  @connectivity     ||= changed['Connectivity']
  active_conn_paths   = changed['ActiveConnections']
  if active_conn_paths
    @connected_to_vpn = on_vpn(nm_service, nm_iface)
  end
  take_action
end

runloop = DBus::Main.new
runloop << bus
begin
  runloop.run
rescue Exception => e
  continue_torrents
  raise
end
