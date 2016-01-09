# -*- mode: tcl; tab-width: 4; indent-tabs-mode: t -*-
#
# fa_adept_client - Itcl class for connecting to and communicating with
#  an Open Aviation Data Exchange Protocol service
#
# Copyright (C) 2014 FlightAware LLC, All Rights Reserved
#
# open source in accordance with the Berkeley license
#

package require tls
package require Itcl

namespace eval ::fa_adept {

set caDir [file join [file dirname [info script]] "ca"]

::itcl::class AdeptClient {
    public variable sock
    public variable host
    public variable hosts [list piaware.flightaware.com piaware.flightaware.com 70.42.6.197 70.42.6.198]
    public variable port 1200
    public variable loginTimeoutSeconds 30
    public variable connectRetryIntervalSeconds 60
    public variable connected 0
    public variable loggedIn 0
	public variable showTraffic 0

    protected variable writabilityTimerID
    protected variable wasWritable 0
    protected variable loginTimerID
    protected variable reconnectTimerID
    protected variable aliveTimerID
    protected variable nextHostIndex 0
    protected variable lastCompressClock 0
    protected variable flushPending 0

    constructor {args} {
		configure {*}$args
    }

    #
    # logger - log a message
    #
    method logger {text} {
		# can also log $this
		::logger $text
    }

	#
	# next_host - return the next host in the list of hosts
	#
	method next_host {} {
		set host [lindex $hosts $nextHostIndex]
		incr nextHostIndex
		if {$nextHostIndex >= [llength $hosts]} {
			set nextHostIndex 0
		}
		return $host
	}

    #
    # tls_callback - routine called back during TLS negotiation
    #
    method tls_callback {cmd channel args} {
		switch $cmd {
			verify {
				lassign $args depth cert status err
				if {!$status} {
					log_locally "TLS verify failed: $err"
					log_locally "Failing certificate:"
					foreach {k v} $cert {
						log_locally "  $k: $v"
					}
				}
				return $status
			}

			error {
				lassign $args message
				log_locally "TLS error: $message"
			}

			info {
				lassign $args major minor message
				if {$major eq "alert"} {
					log_locally "TLS alert: $message"
				} elseif {$major eq "error"} {
					log_locally "TLS error: $message"
				}
			}

			default {
				log_locally "unhandled TLS callback: $cmd $channel $args"
			}
		}
    }

	#
	# cancel_timers - cancel all outstanding connect/alive timers
	#
	method cancel_timers {} {
		cancel_alive_timer
		cancel_login_timer
		cancel_reconnect_timer
		cancel_writability_timer
	}

	#
	# cancel_login_timer - cancel the timer that aborts the connection
	# if we have not successfully logged in after a while
	#
	method cancel_login_timer {} {
		if {[info exists loginTimerID]} {
			after cancel $loginTimerID
			unset loginTimerID
		}
	}

	#
	# cancel_reconnect_timer - cancel the timer that schedules a
	# reconnection
	#
	method cancel_reconnect_timer {} {
		if {[info exists reconnectTimerID]} {
			after cancel $reconnectTimerID
			unset reconnectTimerID
		}
	}

    #
    # connect - close socket if open, then make a TLS connection, then validate
	#  the certificate, then try to login
    #
    method connect {} {
		# close the connection if already connected and cancel the reconnect
		# event timer if there is one
		close_socket
		cancel_timers
		next_host

		log_locally "Connecting to FlightAware adept server at $host/$port"

		# start the connection attempt
		if {[catch {set sock [socket -async $host $port]} catchResult]} {
			log_locally "Connection to adept server at $host/$port failed: $catchResult"
			close_socket_and_reopen
			return 0
		}

		# schedule a timer that gives up if the login doesn't succeed for a while
		set loginTimerID [after [expr {$loginTimeoutSeconds * 1000}] $this abort_login_attempt]

		fileevent $sock writable [list $this connect_completed]
		return 1
	}

	method connect_completed {} {
		if {![info exists sock]} {
			# we raced with a close for some other reason
			return
		}

		# turn off the writability check now
		fileevent $sock writable ""

		set error [fconfigure $sock -error]
		if {$error ne ""} {
			log_locally "Connection to adept server at $host/$port failed: $error"
			close_socket_and_reopen
			return
		}

		log_locally "Connection with adept server at $host/$port established"

		# attempt to connect with TLS negotiation.  Use the included
		# CA cert file to confirm the cert's signature on the certificate
		# the server sends us
		if {[catch {tls::import $sock \
						-cipher ALL \
						-cadir $::fa_adept::caDir \
						-ssl2 0 \
						-ssl3 0 \
						-tls1 1 \
						-require 1 \
						-command [list $this tls_callback]} catchResult] == 1} {
			log_locally "TLS handshake with adept server at $host/$port failed: $catchResult"
			close_socket_and_reopen
			return
		}

		# force the handshake to complete before proceeding
		# we can get errors from this.  catch them and return failure
		# if one occurs.
		if {[catch {::tls::handshake $sock} catchResult] == 1} {
			log_locally "TLS handshake with adept server at $host/$port failed: $catchResult"
			close_socket_and_reopen
			return
		}

		# obtain information about the TLS session we negotiated
		set tlsStatus [::tls::status $sock]
		#logger "TLS status: $tlsStatus"

		# validate the certificate.  error out if it fails.
		if {![validate_certificate_status $tlsStatus reason]} {
			log_locally "Certificate validation with adept server at $host/$port failed: $reason"
			close_socket_and_reopen
			return
		}

		# tls local status are key-value pairs of number of bits
		# in the session key (sbits) and the cipher used, such
		# as DHE-RSA-AES256-SHA
		#logger "TLS local status: [::tls::status -local $sock]"
		log_locally "encrypted session established with FlightAware"

		# configure the socket nonblocking full-buffered and
		# schedule this object's server_data_available method
		# to be invoked when data is available on the socket
		# we arrange to call flush periodically while output is pending,
		# to get better batching of data while still getting it out
		# promptly

		fconfigure $sock -buffering full -buffersize 4096 -blocking 0 -translation binary
		fileevent $sock readable [list $this server_data_available]
		set connected 1
		set flushPending 0

		schedule_writability_check

		# ok, we're connected, now attempt to login
		# note that login reply will be asynchronous to us, i.e.
		# it will come in later
		login
    }

    #
    # validate_certificate_status - return 1 if the certificate looks cool,
	#  else 0
    #
    method validate_certificate_status {statusList _reason} {
        upvar $_reason reason

		array set status $statusList

		# require expected fields
		foreach field "subject issuer notBefore notAfter" {
			if {![info exists status($field)]} {
				set reason "required field '$field' is missing"
				return 0
			}
		}

		# make sure the notBefore time has passed
		set notBefore [clock scan $status(notBefore)]
		set now [clock seconds]

		if {$now < $notBefore} {
			set reason "now is before certificate start time"
			return 0
		}

		# make sure the notAfter time has yet to occur
		set notAfter [clock scan $status(notAfter)]
		if {$now > $notAfter} {
			set reason "certificate expired"
			return 0
		}

		# crack fields in the certificate and require some of them to be present
		crack_certificate_fields $status(subject) subject
		#parray subject

		# validate the common name
		if {![info exist subject(CN)] || ($subject(CN) != "*.flightaware.com" && $subject(CN) != "piaware.flightaware.com" && $subject(CN) != "adept.flightaware.com" && $subject(CN) != "eyes.flightaware.com")} {
			set reason "subject CN is not valid"
			return 0
		}

		log_locally "FlightAware server SSL certificate validated"
		return 1
    }

    #
    # crack_certificate_fields - given a string like CN=foo,O=bar,L=Houston,
	#  crack the key-value pairs into the named array
    #
    method crack_certificate_fields {string _array} {
		upvar $_array array

		foreach pair [split $string ",/"] {
			lassign [split $pair "="] key value
			set array($key) $value
		}

		return
    }

	method abort_login_attempt {} {
		if {![is_connected]} {
			log_locally "Connection attempt with adept server at $host/$port timed out"
		} else {
			log_locally "Login attempt with adept server at $host/$port timed out"
		}
		close_socket_and_reopen
	}

    #
    # server_data_available - callback routine invoked when data is available
	# from the server
    #
    method server_data_available {} {
		# if end of file on the socket, close the socket and attempt to reopen
		if {[eof $sock]} {
			log_locally "Lost connection to adept server at $host/$port: server closed connection"
			close_socket_and_reopen
			return
		}

		# get a line of data from the socket.  if we get an error, close the
		# socket and attempt to reopen
		if {[catch {set size [gets $sock line]} catchResult] == 1} {
			log_locally "Lost connection to adept server at $host/$port: $catchResult"
			close_socket_and_reopen
			return
		}

		#
		# sometimes you get a callback with no data, that's OK but there's nothing to do
		#
		if {$size < 0} {
			return
		}

		if {$showTraffic} {
			puts "< $line"
		}

		#
		# we got a response, convert it to an array and send it to the
		# response handler
		#
		if {[catch {array set response [split $line "\t"]}] == 1} {
			log_locally "malformed message from server ('$line'), disconnecting and reconnecting..."
			close_socket_and_reopen
			return
		}

		if {[catch {handle_response response} catchResult] == 1} {
			log_locally "error handling message '[string map {\n \\n \t \\t} $line]' from server ($catchResult), ([string map {\n \\n \t \\t} [string range $::errorInfo 0 1000]]), disconnecting and reconnecting..."
			close_socket_and_reopen
			return
		}
    }

	#
	# handle_response - handle a response array from the server, invoked from
	#   server_data_available
	#
	method handle_response {_row} {
		upvar $_row row

		switch -glob $row(type) {
			"login_response" {
				handle_login_response_message row
			}

			"notice" {
				handle_notice_message row
			}

			"alive" {
				handle_alive_message row
			}

			"shutdown" {
				handle_shutdown_message row
			}

			"request_auto_update" {
				handle_update_request auto row
			}

			"request_manual_update" {
				handle_update_request manual row
			}

			"mlat_*" {
				forward_to_mlat_client row
			}

			"update_location" {
				handle_update_location row
			}

			default {
				log_locally "unrecognized message type '$row(type)' from server, ignoring..."
				incr ::nUnrecognizedServerMessages
				if {$::nUnrecognizedServerMessages > 20} {
					log_locally "that's too many, i'm disconnecting and reconnecting..."
					close_socket_and_reopen
					set ::nUnrecognizedServerMessages 0
				}
			}
		}
	}

	#
	# handle_login_response_message - handle a login_response message from the
	#  server
	#
	method handle_login_response_message {_row} {
		upvar $_row row

		if {$row(status) == "ok"} {
			set loggedIn 1

			# we got far enough to call this a successful connection, so
			# start again from the start of the host list next time.
			set nextHostIndex 0

			# if the login response contained a user, that's what we're
			# logged in as even if it's not what we might've said or
			# more likely we didn't say
			if {[info exists row(user)]} {
				set ::flightaware_user $row(user)
			}

			# if we received lat/lon data, handle it
			if {[info exists row(recv_lat)] && [info exists row(recv_lon)]} {
				update_location $row(recv_lat) $row(recv_lon)
			}

			log_locally "logged in to FlightAware as user $::flightaware_user"
			cancel_login_timer

			# modern adept servers always send alive messages within the first
			# 60 seconds
			if {![info exists aliveTimerID]} {
				set aliveTimerID [after 90000 [list $this alive_timeout]]
			}
		} else {
			# NB do more here, like UI stuff
			log_locally "*******************************************"
			log_locally "LOGIN FAILED: status '$row(status)': reason '$row(reason)'"
			log_locally "please correct this, possibly using piaware-config"
			log_locally "to set valid Flightaware user name and password."
			log_locally "piaware will now exit."
			log_locally "You can start it up again using 'sudo /etc/init.d/piaware start'"
			exit 4
		}
	}

	#
	# handle_update_location - handle a location-update notification from the server
	#
	method handle_update_location {_row} {
		upvar $_row row
		update_location $row(recv_lat) $row(recv_lon)
	}

	#
	# handle_notice_message - handle a notice message from the server
	#
	method handle_notice_message {_row} {
		upvar $_row row

		if {[info exists row(message)]} {
			log_locally "NOTICE from adept server: $row(message)"
		}
	}

	#
	# handle_shutdown_message - handle a message from the server telling us
	#   that it is shutting down
	#
	method handle_shutdown_message {_row} {
		upvar $_row row

		if {![info exists row(reason)]} {
			set row(reason) "unknown"
		}
		log_locally "NOTICE adept server is shutting down.  reason: $row(reason)"
	}

	#
	# update_check - see if the requested update type (manualUpdate or
	#   autoUpdate) is allowed.
	#
	#   you should be able to inspect this and handle_update_request
	#   and how they're invoked to assure yourself that if there is
	#   no autoUpdate or manualUpdate in /etc/piaware configured true
	#   or by piaware-config configured true, the update cannot occur.
	#
	method update_check {varName} {
		# if there is no matching update variable in the adept config or
		# a global variable set by /etc/piaware, bail
		if {![info exists ::adeptConfig($varName)] && ![info exists ::$varName]} {
			logger "$varName is not configured in /etc/piaware or by piaware-config"
			return 0
		}

		#
		# if there is a var in the adept config and it's not a boolean or
		# it's false, bail.
		#
		if {![info exists ::adeptConfig($varName)]} {
			logger "$varName is not set in adept config, looking further..."
		} else {
			if {![string is boolean $::adeptConfig($varName)]} {
				logger "$varName in adept config isn't a boolean, bailing on update request"
				return 0
			}

			if {!$::adeptConfig($varName)} {
				logger "$varName in adept config is disabled, disallowing update"
				return 0
			} else {
				# the var is there and set to true, we proceed with the update
				logger "$varName in adept config is enabled, allowing update"
				return 1
			}
		}

		if {[info exists ::$varName]} {
			set val [set ::$varName]
			if {![string is boolean $val]} {
				logger "$varName in /etc/piaware isn't a boolean, bailing on update request"
				return 0
			} else {
				if {$val} {
					# the var is there and true, proceed
					logger "$varName in /etc/piaware is enabled, allowing update"
					return 1
				} else {
					# the var is there and false, bail
					logger "$varName in /etc/piaware is disabled, disallowing update"
					return 0
				}
			}
		}

		# this shouldn't happen
		logger "software error detected in update_check, disallowing update"
		return 0
	}

	#
	# handle_update_request - handle a message from the server requesting
	#   that we update the software
	#
	method handle_update_request {type _row} {
		upvar $_row row

		# force piaware config and adept config reload in case user changed
		# config since we last looked
		load_piaware_config
		load_adept_config

		switch $type {
			"auto" {
				logger "auto update (flightaware-initiated) requested by adept server"
			}

			"manual" {
				logger "manual update (user-initiated via their flightaware control page) requested by adept server"
			}

			default {
				logger "update request type must be 'auto' or 'manual', ignored..."
				return
			}
		}

		# see if we are allowed to do this
		if {![update_check ${type}Update]} {
			# no
			return
		}

		if {![info exists row(action)]} {
			error "no action specified in update request"
		}

		logger "performing $type update, action: $row(action)"

		set restartPiaware 0
		foreach action [split $row(action) " "] {
			switch $action {
				"full" {
					update_operating_system_and_packages
				}

				"packages" {
					upgrade_raspbian_packages
				}

				"piaware" {
					# only restart piaware if upgrade_piaware said it upgraded
					# successfully
					set restartPiaware [upgrade_piaware]
				}

				"restart_piaware" {
					set restartPiaware 1
				}

				"dump1090" {
					# try to upgrade dump1090 and if successful, restart it
					if {[upgrade_dump1090]} {
						attempt_dump1090_restart
					}
				}

				"restart_dump1090" {
					attempt_dump1090_restart
				}

				"reboot" {
					reboot
				}

				"halt" {
					halt
				}

				default {
					logger "unrecognized update action '$action', ignoring..."
				}
			}
		}

		logger "update request complete"

		if {$restartPiaware} {
			restart_piaware
		}
	}

	#
	# handle_alive_message - handle an alive message from the server
	#
	method handle_alive_message {_row} {
		upvar $_row row

		# get the system clock on the local pi
		set now [clock seconds]

		if {![info exists row(interval)]} {
			set row(interval) 300
		}
		set afterMS [expr {round($row(interval) * 1000 * 1.2)}]

		# cancel the current alive timeout timer if it exists
		cancel_alive_timer

		# schedule alive_timeout to run in the future
		set aliveTimerID [after $afterMS [list $this alive_timeout]]

		if {[info exists row(clock)]} {
			set ::myClockOffset [expr {$now - $row(clock)}]
		}
	}

	#
	# cancel_alive_timer - cancel the alive timer if it exists
	#
	method cancel_alive_timer {} {
		if {![info exists aliveTimerID]} {
			#log_locally "cancel_alive_timer: no extant timer ID, doing nothing..."
		} else {
			if {[catch {after cancel $aliveTimerID} catchResult] == 1} {
				#log_locally "cancel_alive_timer: cancel failed: $catchResult"
			} else {
				#log_locally "cancel_alive_timer: canceled $aliveTimerID"
			}
			unset aliveTimerID
		}
	}

	#
	# alive_timeout - this is called if the alive timer isn't canceled before
	#  it goes off
	#
	method alive_timeout {} {
		log_locally "timed out waiting for alive message from FlightAware, reconnecting..."
		close_socket_and_reopen
	}

    #
    # close_socket - close the socket, forcibly if necessary
    #
    method close_socket {} {
		set connected 0
		set loggedIn 0

		if {[info exists sock]} {
			# we don't care about why it didn't close if it doesn't
			# close cleanly...
			# we used to log this and it's just dumb and confusing
			catch {close $sock}
			unset sock
		}

		disable_mlat
    }

    #
    # close_socket_and_reopen - close the socket and reopen it
    #
    method close_socket_and_reopen {} {
		close_socket
		cancel_timers

		set interval [expr {round(($connectRetryIntervalSeconds * (1 + rand())))}]
		log_locally "reconnecting in $interval seconds..."

		set reconnectTimerID [after [expr {$interval * 1000}] [list $this connect]]
    }

	#
	# login - attempt to login
	#
	# invoked from connect after successful TLS negotiation
	#
	method login {} {
		if {![is_connected]} {
			error "tried to login while not connected"
		}

		set message(type) login

		# construct some key-value pairs to be included.
		foreach var "user password image_type piaware_version piaware_version_full piaware_package_version dump1090_packages" globalVar "::flightaware_user ::flightaware_password ::imageType ::piawareVersion ::piawareVersionFull ::piawarePackageVersion ::dump1090Packages" {
			if {[info exists $globalVar] && [set $globalVar] ne ""} {
				set message($var) [set $globalVar]
			}
		}

		catch {set message(uname) [exec /bin/uname --all]}

		if {[info exists ::netstatus(program_30005)]} {
			set message(adsbprogram) $::netstatus(program_30005)
		}

		set message(transprogram) "faup1090"

		set message(mac) [get_mac_address_or_quit]

		catch {
			if {[get_default_gateway_interface_and_ip gateway iface ip]} {
				set message(local_ip) $ip
				set message(local_iface) $iface
			}
		}

		catch {
			get_os_release rel
			foreach {k1 k2} {ID os_id VERSION_ID os_version_id VERSION os_version} {
				if {[info exists rel($k1)]} {
					set message($k2) $rel($k1)
				}
			}
		}

		set message(local_auto_update_enable) [update_check autoUpdate]
		set message(local_manual_update_enable) [update_check manualUpdate]
		set message(local_mlat_enable) [mlat_is_configured]

		set message(compression_version) 1.2

		send_array message
	}

	#
	# get_mac_address - return the mac address of eth0 as a unique handle
	#  to this device.
	#
	#  if there is no eth0 tries to find another mac address to use that it
	#  can hopefully repeatably find in the future
	#
	#  if we can't find any mac address at all then return an empty string
	#
	method get_mac_address {} {
		if {[info exists ::macAddress]} {
			return $::macAddress
		}

		set macFile /sys/class/net/eth0/address
		if {[file readable $macFile]} {
			set fp [open $macFile]
			gets $fp mac
			set ::macAddress $mac
			close $fp
			return $mac
		}

		# well, that didn't work, look at the entire output of ifconfig
		# for a MAC address and use the first one we find

		if {[catch {set fp [open "|ifconfig"]} catchResult] == 1} {
			puts stderr "ifconfig command not found on this version of Linux, you may need to install the net-tools package and try again"
			return ""
		}

		set mac ""
		while {[gets $fp line] >= 0} {
			set mac [::fa_adept::parse_mac_address_from_line $line]
			set device ""
			regexp {^([^ ]*)} $line dummy device
			if {$mac != ""} {
				# gotcha
				set ::macAddress $mac
				log_locally "no eth0 device, using $mac from device '$device'"
				break
			}
		}

		catch {close $fp}
		return $mac
	}

	#
	# get_mac_address_or_quit - return the mac address of eth0 or if unable
	#  to, emit a message to stderr and exit
	#
	method get_mac_address_or_quit {} {
		set mac [get_mac_address]
		if {$mac == ""} {
			puts stderr "software failed to determine MAC address of the device.  cannot proceed without it."
			exit 6
		}
		return $mac
	}

    #
    # is_connected - return 1 if the session is connected, otherwise 0
    #
    method is_connected {} {
		return $connected
    }

    #
    # is_logged_in - return 1 if the session is logged in, otherwise 0
    #
    method is_logged_in {} {
		return $loggedIn
    }

    #
    # send - send the message to the server.  if puts returns an error,
	#  disconnects and schedules reconnection shortly in the future
    #
    method send {text} {
		if {![is_connected]} {
			# we might be halfway through a reconnection.
			# drop data on the floor
			return
		}

		if {$showTraffic} {
			puts "> $text"
		}

		if {[catch {puts $sock $text} catchResult] == 1} {
			log_locally "got '$catchResult' writing to FlightAware socket, reconnecting..."
			close_socket_and_reopen
			return
		}

		if {!$flushPending} {
			set flushPending 1
			after 200 [list $this flush_output]
		}
    }

	# flush any buffered output
	method flush_output {} {
		set flushPending 0
		if {[info exists sock]} {
			if {[catch {flush $sock} catchResult] == 1} {
				log_locally "got '$catchResult' writing to FlightAware socket, reconnecting..."
				close_socket_and_reopen
				return
			}
		}
	}

	#
	# send_array - send an array as a message
	#
	method send_array {_row} {
		upvar $_row row

		if {[info exists row(clock)]} {
			set now [clock seconds]
			if {abs($now - $row(clock)) > 1} {
				set row(sent_at) $now
			}
		} else {
			set row(clock) [clock seconds]
		}

		if {$loggedIn} {
			compress_array row
		}

		set message ""
		foreach field [lsort [array names row]] {
			append message "\t$field\t$row($field)"
		}

		send [string range $message 1 end]
	}

	#
	# compress_array - compress some of the key-value pairs in the array
	# into a single quoted binary key-value pair
	#
	method compress_array {_row} {
		upvar $_row row

		set newKey "!"
		set binData ""

		# remove clocks from consecutive messages that are the same as
		# the last clock emitted
		if {[info exists row(clock)]} {
			if {$row(clock) == $lastCompressClock} {
				unset row(clock)
			} else {
				set lastCompressClock $row(clock)
			}
		}

		foreach "var keyChar format" "clock c I sent_at C I hexid h H6 ident i A8 alt a I lat l R lon m R speed s S squawk q H4 heading H S" {
			if {[info exists row($var)]} {
				append newKey $keyChar
				append binData [binary format $format $row($var)]
				unset row($var)
			}
		}

		# These keys expect a list-format value:
		foreach "var keyChar format" "m_short S H12H14 m_long L H12H28 m_sync Y H12H28H12H28" {
			if {[info exists row($var)]} {
				append newKey $keyChar
				append binData [binary format $format {*}$row($var)]
				unset row($var)
			}
		}

		# encode airGround into special key if G and remove completely if A
		if {[info exists row(airGround)]} {
			if {$row(airGround) == "G"} {
				append newKey g
			}
			unset row(airGround)
		}

		# encode tabs and newlines and whatnot
		set binData [string map {\t \\t \\ \\\\ \n \\n} $binData]

		set row($newKey) $binData
		return
	}

	#
	# schedule_writability_check:
	#   every 10 seconds, set up a fileevent callback to check for socket writability
	#   if/when the fileevent callback fires, remove the callback and set a flag
	#   when the timer next fires, if the flag isn't set, then give up and abort
	#
	method schedule_writability_check {} {
		cancel_writability_timer
		set wasWritable 0
		set writabilityTimerID [after 10000 [list $this check_writability]]
		catch {fileevent $sock writable [list $this socket_was_writable]}
	}

	method socket_was_writable {} {
		set wasWritable 1
		fileevent $sock writable ""
	}

	method check_writability {} {
		if {!$wasWritable} {
			log_locally "data isn't making it to FlightAware, reconnecting..."
			close_socket_and_reopen
		} else {
			schedule_writability_check
		}
	}

	method cancel_writability_timer {} {
		if {[info exists writabilityTimerID]} {
			after cancel $writabilityTimerID
			unset writabilityTimerID
		}
	}
}

#
# ca_crt_file - dig the location of the ca.crt file shipped inside the
#  fa_adept_client package and return the path to the ca.crt file
#
proc ca_crt_file {} {
    set loadCommand [package ifneeded fa_adept_client [package require fa_adept_client]]

    if {![regexp {source (.*)} $loadCommand dummy path]} {
		error "software failure finding ca crt file"
    }

    return [file dir $path]/ca.crt
}

#
# parse_mac_address_from_line - find a mac address free-from in a line and
#   return it or return the empty string
#
proc parse_mac_address_from_line {line} {
	if {[regexp {(([0-9a-fA-F]{2}[:-]){5}([0-9a-fA-F]{2}))} $line dummy mac]} {
		return $mac
	}
	return ""
}

} ;# namespace fa_adept

package provide fa_adept_client 0.0

# vim: set ts=4 sw=4 sts=4 noet :

