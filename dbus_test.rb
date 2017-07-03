#!/usr/bin/env ruby

require 'dbus'

bus = DBus.system_bus
nm_service = bus.service('org.freedesktop.NetworkManager')
nm_object = nm_service.object('/org/freedesktop/NetworkManager/Settings')
nm_iface = nm_object['org.freedesktop.NetworkManager.Settings']
conns = nm_iface.ListConnections.first
conns.each do |conn|
  # conn is like "/org/freedesktop/NetworkManager/Settings/N"
  conn =~ /\/(\d+)\z/
  n = $1.to_i
  conn_object = nm_service.object(conn)
  conn_iface = conn_object['org.freedesktop.NetworkManager.Settings.Connection']
  puts "Setting #{n}: #{conn_iface.GetSettings}"
end
