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
SLEEP = 0.5
TICK  = 5

DEBUG_LOG = false

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

@queue = Queue.new


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


def routes_present?
   `ip route`.lines.grep(/0\.0\.0\/1 via.*tun0/).count == 2
end


def on_vpn(nm_service, nm_iface)
  retries = 2
  begin
    settings = Setting.get_settings(nm_service)
  rescue DBus::Error
    if retries > 0
      retries -= 1
      $stdout.write( "#{Time.now} Caught #{$!} but sleeping and retrying (#{retries} left)\n" ); $stdout.flush
      sleep SLEEP
      retry
    end
  end
  active_conn_paths = nm_iface['ActiveConnections']
  active_settings = get_active_settings(nm_service, active_conn_paths, settings)
  active_settings.count{|s| s.id == CONNECTION_ID } > 0
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
      #$stdout.write( "Setting #{n}: #{conn_iface.GetSettings}\n\n\n" ); $stdout.flush
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


class QueueConsumer
  EVENTS = [:connect, :disconnect, :tick]

  def self.consume(queue)
    state = nil    #STATES:  :disconnected, :connected, :connect_when_safe
    def transition(old_state, new_state)
      "#{old_state} -> #{new_state}"
    end
    Thread.new do 
      loop do
        event = queue.pop
        if DEBUG_LOG
          $stdout.write "#{Time.now} DEBUG: QueueConsumer: received #{event} from queue\n"
          $stdout.flush
        end
        raise "unexpected queue event: #{event.inspect}" unless EVENTS.include? event
        if event == :disconnect
          old_state = state
          state = :disconnected
          $stdout.write( "#{Time.now} (EVT:#{event}; #{transition(old_state, state)}) Pausing\n" ); $stdout.flush
          pause_torrents
          alarm unless old_state == :disconnected
        elsif event == :connect
          if routes_present?
            old_state = state
            state = :connected
            $stdout.write( "#{Time.now} (EVT:#{event}; #{transition(old_state, state)}) Continuing\n" ); $stdout.flush
            continue_torrents
          else
            $stdout.write( "#{Time.now} (EVT:#{event}; #{state}) Not continuing because routes not present (and pausing for extra safety)\n" ); $stdout.flush
            pause_torrents
            state = :connect_when_safe
          end
        elsif event == :tick
          if state == :connect_when_safe
            if routes_present?
              old_state = state
              state = :connected
              $stdout.write( "#{Time.now} (EVT:#{event}; #{transition(old_state, state)}) Continuing now that routes are safe\n" ); $stdout.flush
              continue_torrents
            else
              $stdout.write( "#{Time.now} (EVT:#{event}; #{state}) Not continuing because routes are still not present (and pausing for extra safety)\n" ); $stdout.flush
              pause_torrents
            end
          end
        else
          raise "wtf"
        end
      end
    end
  end
end


def tick_sender_thread(queue)
  Thread.new do
    loop do
      sleep TICK
      if DEBUG_LOG
        $stdout.write "#{Time.now} DEBUG: pushing :tick to queue\n"
        $stdout.flush
      end
      queue.push :tick
    end
  end
end


bus = DBus.system_bus
nm_service = bus.service('org.freedesktop.NetworkManager')


nm_obj   = nm_service.object('/org/freedesktop/NetworkManager')
nm_iface = nm_obj['org.freedesktop.NetworkManager']

# Connectivity states: https://developer.gnome.org/NetworkManager/unstable/nm-dbus-types.html#NMConnectivityState
@connectivity = nm_iface['Connectivity']
active_conn_paths = nm_iface['ActiveConnections']
@connected_to_vpn = on_vpn(nm_service, nm_iface)
if @connectivity >= 2 && !@connected_to_vpn
  $stdout.write( "#{Time.now} Pausing\n" ); $stdout.flush
  pause_torrents
  alarm
else
  $stdout.write( "#{Time.now} Continuing\n" ); $stdout.flush
  continue_torrents
end

nm_iface.on_signal('PropertiesChanged') do |changed|
  if DEBUG_LOG
    $stdout.write "#{Time.now} DEBUG: received PropertiesChanged\n"
    $stdout.flush
  end
  @connectivity     ||= changed['Connectivity']
  active_conn_paths   = changed['ActiveConnections']
  if active_conn_paths
    @connected_to_vpn = on_vpn(nm_service, nm_iface)
  end
  if @connectivity >= 2 && !@connected_to_vpn
    if DEBUG_LOG
      $stdout.write "#{Time.now} DEBUG: pushing :disconnect to queue\n"
      $stdout.flush
    end
    @queue.push(:disconnect)
  else
    if DEBUG_LOG
      $stdout.write "#{Time.now} DEBUG: pushing :connect to queue\n"
      $stdout.flush
    end
    @queue.push(:connect)
  end
end

#### Start other threads and then runloop
QueueConsumer.consume(@queue)
tick_sender_thread(@queue)

runloop = DBus::Main.new
runloop << bus
begin
  runloop.run
rescue Exception => e
  $stdout.write( "#{Time.now} caught fatal exception #{e}; pausing torrents and exiting\n" ); $stdout.flush
  pause_torrents
  raise
end
