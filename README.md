No VPN, No Torrents!
=====================

This is a Linux-only script to pause your torrent client whenever your VPN isn't running, and resume it when the VPN is running again. It plays a sound every time it pauses your torrent client, to remind you to turn on your VPN.

It runs continuously, listening for D-Bus events from NetworkManager. If your system doesn't run that, then this isn't supported.

Currently, configuration is via editing the constants at the top of the file.

Pull requests are welcome!
