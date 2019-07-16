package require Tcl 8.6

namespace eval ::w1 {
    namespace eval vars {
        variable -root  "/sys/bus/w1/devices"
        variable -slave "w1_slave"
        variable -poll  10

        variable addrPattern {[0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F]}
        variable 0K -273.15
    }

    namespace export {[a-z]*}
    namespace ensemble create -command ::onewire
}


# ::w1::devices -- List connected 1-wire devices
#
#       List the connected 1-wire devices matching a given family pattern. By
#       default, the pattern will match any known family.
#
# Arguments:
#       family  Pattern matching the device family, matches all known by default.
#
# Results:
#       A list of local devices matching the family pattern
#
# Side Effects:
#       None.
proc ::w1::devices { {family {[0-9a-fA-F][0-9a-fA-F]}}} {
    return [glob -nocomplain -directory ${vars::-root} -tails -- ${family}-$vars::addrPattern]
}


# ::w1::bind -- Bind device to variable
#
#       Binds the value of a device to a fully-qualified variable. This arranges
#       for the device to be regularily polled for its value and the content of
#       the variable to be updated each time a proper value could be acquired.
#       When the type of the device is not given, this will be guessed from the
#       device family. At present, only TEMP is recognised.
#
# Arguments:
#       dev     ID of device, as returned by devices for example.
#       var     Fully-qualified of destination variable.
#       period  (fractional) number of seconds to poll device for content,
#               negative for -poll
#       type    Type of device, right now only TEMP is recognised. Empty (default)
#               for guess out of device family
#
# Results:
#       None.
#
# Side Effects:
#       The variable will first be set to an impossible value (0 Kelvin), then
#       will be kept updated with the value reported by the sensor for every
#       successful reading.
proc ::w1::bind { dev var {period -1} {type ""} } {
    # Guess type from 1-wire family when none given
    if { $type eq "" } {
        set family [string range $dev 0 1]
        switch -glob -nocase -- $family {
            10 -
            22 -
            28 -
            3B -
            42 {
                # Above are the family codes for the thermometer sensors
                # recognised by the w1_therm module. See:
                # https://www.kernel.org/doc/Documentation/w1/slaves/w1_therm
                set type TEMP
            }
        }
    }

    # Period is in fractional seconds, when negative take the default from the
    # main variables.
    if { $period < 0 } {
        set period ${vars::-poll}
    }
    set period [expr {int(1000.0*$period)}]

    switch -nocase -glob -- $type {
        "TEMP*" {
            set $var $vars::0K
            every $period [list [namespace current]::temperature $dev [list [namespace current]::SetVar $var $vars::0K]]
        }
        default {
            return -code error "Unknown type: $type"
        }
    }
}


# ::w1::every -- Repeat command every x milliseconds
#
#       Periodically invoke a command
#
# Arguments:
#       ms      Period for invocation, in milliseconds.
#       cmd     Command to execute.
#
# Results:
#       None.
#
# Side Effects:
#       None.
proc ::w1::every { ms cmd } {
    {*}$cmd
    after $ms [list after idle [namespace code [info level 0]]]
}


# ::w1::temperature -- Get temperature at sensor
#
#       (A)synchronously get the temperature at a given sensor. The sensor need
#       to be one of the sensors recognised by the w1_therm kernel module, see:
#       https://www.kernel.org/doc/Documentation/w1/slaves/w1_therm. On all
#       errors, the temperature reported will be the 0 Kelvin. Whenever a
#       command is given, reading will occur asynchronously and the temperature
#       that was read will be added as a paramter to the callback command once
#       the reading has ended.
#
# Arguments:
#       dev     ID of sensor.
#       cmd     Command to callback with current temperature.
#
# Results:
#       Temperature at the sensor, 0K on all errors.
#
# Side Effects:
#       Will initiate a 1-wire reading at the sensor.
proc ::w1::temperature { dev {cmd {}} } {
    set fpath ${vars::-root}/$dev/${vars::-slave}
    if { [catch {open $fpath r} fd] == 0 } {
        # When a command is provided, arrange for reading to occur in
        # non-blocking mode and read through the state-machine.
        if { [llength $cmd] } {
            fconfigure $fd -blocking off -buffering line
            fileevent $fd readable [list [namespace current]::AsyncReader TEMP CRC $fd $cmd]
        } else {
            # When no command is provided, read directly and in blocking mode.
            # First check that the word YES is present in the first row, then
            # read the value of the temperature. This is documented at
            # https://www.kernel.org/doc/Documentation/w1/slaves/w1_therm.
            set temp $vars::0K
            set line [HexClean [gets $fd]]
            if { [string match *YES* $line] } {
                set line [HexClean [gets $fd]]
                set temp [regsub {t=} $line ""]
            }
            close $fd
            return [expr {$temp/1000.0}]
        }
    } else {
        # Error, mediate this whichever way is best for the caller.
        if { [llength $cmd] } {
            {*}$cmd $vars::0K
        } else {
            return $vars::0K
        }
    }
}


# ::w1::SetVar -- Set exernal variable with sensor value
#
#       Whenever it is not an error, set the value of a (fully-qualified)
#       variable to the value of a sensor.
#
# Arguments:
#       var     Fully-qualified name of variable.
#       errval  Error value, skip when the value is equal to this.
#       val     Value reported by sensor.
#
# Results:
#       None.
#
# Side Effects:
#       Change value of (external) variable.
proc ::w1::SetVar { var errval val } {
    if { $val != $errval } {
        set $var $val
    }
}


# ::w1::AsyncReader -- State-machine for reading slaves
#
#       State-machine implementation for reading the value of 1-wire slave
#       sensors. At present, only the type TEMP is implemented, which will work
#       for all sensors supported by the w1_therm kernel module. In that case,
#       the state-machine verifies that the CRC of the reading was proper before
#       reading the value and reporting.
#
# Arguments:
#       type    Type of sensor, only TEMP is recognised at present.
#       state   Current state.
#       fd      Descriptor to read from.
#       cmd     Command to call on success/failure.
#
# Results:
#       None.
#
# Side Effects:
#       For the TEMP type, on all errors, the command will be called with 0K as
#       the value. Otherwise, this will be the temperature at the sensor in
#       Celsius.
proc ::w1::AsyncReader { type state fd cmd } {
    switch -nocase -glob -- $type {
        "TEMP*" {
            switch -exact -nocase -- $state {
                "CRC" {
                    OnLine $type $fd [list {*$cmd $vars::0K}] $cmd {
                        {type fd cmd line} {
                            if { [string match *YES* [HexClean $line]] } {
                                fileevent $fd readable [list [namespace current]::AsyncReader $type VAL $fd $cmd]
                            } else {
                                {*}$cmd $vars::0K
                            }
                        }
                        ::w1
                    }
                }
                "VAL" {
                    OnLine $type $fd [list {*$cmd $vars::0K}] $cmd {
                        {type fd cmd line} {
                            set temp [regsub {t=} [HexClean $line] ""]
                            set temp [expr {$temp/1000.0}]
                            {*}$cmd $temp
                            close $fd
                        }
                        ::w1
                    }
                }
            }
        }
    }
}


# ::w1::OnLine -- Call lambda when proper line read
#
#       This is a helper that will read a line from a non-blocking descriptor
#       and either call an error command whenever reading could not happen, or a
#       lambda with the line when it has been acquired from the descriptor.
#
# Arguments:
#       type    Type of sensor.
#       fd      Descriptor to read from.
#       errcmd  Command to call on failure.
#       cmd     Command to call on success.
#       func    Lambda to pass most parameters and line on successful read.
#
# Results:
#       None.
#
# Side Effects:
#       Call error command on problems, otherwise passes line and most
#       parameters back to lambda.
proc ::w1::OnLine { type fd errcmd cmd func } {
    # Read a line from the file descriptor and pass it to an anonymous function.
    if { [gets $fd line] < 0 } {
        if { [eof $fd] } {
            {*}$errcmd
            close $fd
        }
        # Could not read a complete line this time, just wait until we are
        # called again. The content will be buffered until then.
    } else {
        # We had a line, pass it further to the function.
        apply $func $type $fd $cmd $line
    }
}


# ::w1::HexClean -- Clean HEX
#
#       Clean leading HEX value from w1_therm supported sensor reading lines.
#
# Arguments:
#       line    Line to remove HEX headers from.
#
# Results:
#       Cleaned line.
#
# Side Effects:
#       None.
proc ::w1::HexClean { line } {
    regsub -all {[0-9a-fA-F][0-9a-fA-F] } $line ""
}


# If we are not being included in another script, run a quick test
if {[file normalize $::argv0] eq [file normalize [info script]]} {
    # Enumerate all devices
    puts "Known devices: [onewire devices]"
    # Enumerate all devices for a given family, e.g DS18B20
    puts "Known DS18B20: [onewire devices 28]"
    # Get the temperature for all of the same family as above
    foreach dev [onewire devices 28] {
        puts "Temperature at $dev is [onewire temperature $dev]"
    }

    # Pick a device a bind it to a variable. The variable will first be set to
    # an "error" value and will then be set for every successful reading. In
    # that case, the frequency is in fractional seconds from the -poll main
    # variable, but it can also be passed as the third argument to the procedure
    # instead. Reading occurs in the backgound
    set pool [lindex [onewire devices 28] 0]
    onewire bind $pool ::temp

    # Wait for the variable to be set and output what was read.
    vwait forever
    puts "Temperature at $dev was set once to $::temp"
}
