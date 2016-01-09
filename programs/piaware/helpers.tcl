# -*- mode: tcl; tab-width: 4; indent-tabs-mode: t -*-
#
# fa_adept_client - open data exchange protocol server
#
# Copyright (C) 2014 FlightAware LLC, All Rights Reserved
#

package require tls

#
# logger - log a message
#
proc logger {text} {
	#::bsd::syslog log info $text
	log_locally $text
	if {[llength [info commands "adept"]] < 1} {
	     # adept client has not yet loaded
	     return 0
	}
}

#
# log_locally - log a message locally
#
proc log_locally {text} {
	#::bsd::syslog log info $text
    puts stderr "[clock format [clock seconds] -format "%D %T" -gmt 1] $text"
}

#
# greetings - issue a startup message
#
proc greetings {} {
	log_locally "****************************************************"
	log_locally "piaware version $::piawareVersionFull is running, process ID [pid]"
	log_locally "your system info is: [exec /bin/uname --all]"
}

#
# setup_adept_client - adept client-side setup
#
proc setup_adept_client {} {
	if {$::params(serverhosts) == ""} {
		set hostOptions ""
	} else {
		set hostOptions "-hosts $::params(serverhosts)"
	}

    ::fa_adept::AdeptClient adept \
		-port $::params(serverport) \
		-showTraffic $::params(showtraffic) \
		{*}$hostOptions
}

#
# load_adept_config_and_setup - load config and massage if necessary
#
proc load_adept_config_and_setup {} {
	load_adept_config

	if {[info exists ::adeptConfig(user)]} {
		set ::flightaware_user $::adeptConfig(user)
	}

	if {[info exists ::adeptConfig(password)]} {
		set ::flightaware_password $::adeptConfig(password)
	}

	lassign [load_location_info] ::receiverLat ::receiverLon

	return 1
}

#
# user_password_sanity_check - return 0 if either of the variables
#  flightaware_user and flightaware_password don't exist or are
#  empty, else 1.
#
proc user_password_sanity_check {} {
	foreach var "::flightaware_user ::flightaware_password" {
		if {![info exists $var]} {
			return 0
		}

		if {[set $var] == ""} {
			return 0
		}
	}

	return 1
}

#
# confirm_nonblank_user_and_password_or_die - either we have existant, non-blank
#  passwords or we die
#
proc confirm_nonblank_user_and_password_or_die {} {
	if {![user_password_sanity_check]} {
		puts stdout "FlightAware account user and password settings are empty or missing"
		puts stdout "Please run piaware-config to update"
		exit 1
	}
}

# log_stdout_stderr_to_file - redirect stdout and stderr to a log file
#
proc log_stdout_stderr_to_file {} {
	# log to /tmp/piaware.out
	set fp [open /tmp/piaware.out a]
	fconfigure $fp -buffering line
	dup $fp stdout
	dup $fp stderr
	close $fp
}

#
# switch_logfile - close and rename the log file and open a new one
#
proc switch_logfile {} {
	log_locally "switching log files"
	file rename -force -- /tmp/piaware.out /tmp/piaware.out.yesterday
	log_stdout_stderr_to_file
}

#
# schedule_logfile_switch - schedule a logfile switch in the appropriate number
#  of milliseconds that it's at midnight
#
proc schedule_logfile_switch {} {
	set now [clock seconds]

	if {$now < 1423000000} {
		log_locally "schedule_logfile_switch: system clock isn't current ($now), should be at least 1423000000, maybe ntpd hasn't synchronized time yet, will check again in a minute"
		after 60000 schedule_logfile_switch
		return
	}

	set secsPerDay 86400
	set clockAtNextMidnight [expr {(((($now + 60) / $secsPerDay) + 1) * $secsPerDay) - 1}]
	set secondsUntilMidnight [expr {$clockAtNextMidnight - $now}]
	after [expr {$secondsUntilMidnight * 1000}] schedule_logfile_switch_and_switch_logfile
}

#
# schedule_logfile_switch_and_switch_logfile - schedule the next logfile
#  switch and perform the current logfile switch
#
proc schedule_logfile_switch_and_switch_logfile {} {
	schedule_logfile_switch
	switch_logfile
}

#
# create_pidfile - create a pidfile for this process if possible if so
#   configured
#
proc create_pidfile {} {
	set file $::params(p)
	if {$file == ""}  {
		return
	}

	log_locally "creating pidfile $file"

	# a+ so we have write access but don't fail on missing files and don't clobber existing data
	set ::pidfile [open $file "a+"]
	if {![flock -write -nowait $::pidfile]} {
		close $::pidfile
		unset ::pidfile
		log_locally "unable to lock pidfile $file; is another piaware instance running?"
		exit 2
	}
	chan seek $::pidfile 0 start
	chan truncate $::pidfile 0
	puts $::pidfile [pid]
	flush $::pidfile
	set ::pidfileIsMine 1

	# keep the pidfile open so we maintain the lock
}

#
# unlock_pidfile - release any lock on the pidfile,
# but otherwise leave the file alone
proc unlock_pidfile {} {
	if {![info exists ::pidfile]} {
		return
	}

	# closing releases our lock
	close $::pidfile
	unset ::pidfile

	# no longer safe to delete the pidfile
	# as someone else may overwrite it
	unset -nocomplain ::pidfileIsMine
}

#
# remove_pidfile - remove the pidfile if it exists
#
proc remove_pidfile {} {
	if {![info exists ::pidfileIsMine]} {
		return
	}

	# delete before unlocking to avoid a race with a concurrently starting
	# piaware
	log_locally "removing pidfile $::params(p)"
	if {[catch {file delete $::params(p)} catchResult] == 1} {
		log_locally "failed to remove pidfile: $catchResult, continuing..."
	}

	unset ::pidfileIsMine
	unlock_pidfile
}

#
# setup_signals - arrange for common signals to shutdown the program
#
proc setup_signals {} {
	signal trap HUP "shutdown %S"
	signal trap TERM "shutdown %S"
	signal trap INT "shutdown %S"
}

#
# shutdown - shutdown signal handler
#
proc shutdown {{reason ""}} {
	logger "$::argv0 (process [pid]) is shutting down because it received a shutdown signal ($reason) from the system..."
	cleanup_and_exit
}

#
# cleanup_and_exit - stop faup1090 if it is running and remove the pidfile if
#  we created one
#
proc cleanup_and_exit {} {
	stop_faup1090
	disable_mlat
	remove_pidfile
	logger "$::argv0 (process [pid]) is exiting..."
	exit 0
}

#
# load lat/lon info if available
#
proc load_location_info {} {
	if {[catch {set ll [try_load_location_info]}] == 1} {
		return [list "" ""]
	}

	return $ll
}

proc try_load_location_info {} {
	set fp [open $::locationFile r]
	set data [read $fp]
	close $fp

	lassign [split $data "\n"] lat lon
	if {![string is double $lat] || ![string is double $lon]} {
		error "lat/lon missing or not numeric"
	}

	return [list $lat $lon]
}

# save location info
proc save_location_info {lat lon} {
	if {[catch {try_save_location_info $lat $lon} catchResult] == 1} {
		log_locally "got '$catchResult' trying to update $::locationFile"
	}
}

proc try_save_location_info {lat lon} {
	set dir [file dirname $::locationFile]
	if {![file exists $dir]} {
		file mkdir $dir
	}

	set fp [open $::locationFile w]
	puts $fp $lat
	puts $fp $lon
	close $fp
}

# vim: set ts=4 sw=4 sts=4 noet :
