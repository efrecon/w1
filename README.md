# 1-Wire Slave Interface

This Tcl module implements a number of services for easily reading the value of
the 1-wire slave sensors supported by the Linux kernel module. At present, only
sensors supported by the [w1_therm] module are supported. This library has only
been tested on the raspberry Pi.

  [w1_therm]: https://www.kernel.org/doc/Documentation/w1/slaves/w1_therm

## Raspberry Pi Initialisation

At first, you should ensure that the Raspberry Pi is setup for 1-wire over GPIO.
This can be done through `raspi-config` or by adding a line similar to the
following one to `/boot/config.txt` (and reboot).

```ini
dtoverlay=w1-gpio
```

Once you have rebooted, enter the following two commands for enabling the proper
kernel modules:

```shell
sudo modprobe w1-gpio
sudo modprobe w1-therm
```

To arrange for those kernel modules to be loaded at every boot, you can add them
to `/etc/modules`.

## Library Testing

The library comes with a simple self-test. Provided that you have connected a
temperature sensor supported by the [w1_therm] kernel module, you should be able
to read its value through entering the following command. For a wiring example,
see [this][circuitbasics] tutorial.

```shell
tclsh8.6 w1.tcl
```

  [circuitbasics]: http://www.circuitbasics.com/raspberry-pi-ds18b20-temperature-sensor-tutorial/

Reading the code of the self-test will provide good insights into the various
functions implemented by the library. These are detailed below and fully
commented in the code.

## API

The library is encapsulated within the namespace `w1` and is provided under a
namespace ensemble called `onewire`. This means that the following two commands
are equivalent:

```tcl
::w1::devices
onewire devices
```

### Listing Devices

To list known and connected devices that have been recognised by the 1-wire kernel module, you can call the following command:

```tcl
onewire devices
```

The command actually takes an additional argument that is a pattern matching
against the family of the 1-wire sensor device. So to list only the [DS18B20]
devices, you could call the following command instead (`28` is the HEX code for
the [DS18B20] family of devices).

```tcl
onewire devices 28
```

  [DS18B20]: https://www.maximintegrated.com/en/products/sensors/DS18B20.html

### Getting a Temperture Measurement

Given the identifier of a temperature sensor returned by the previous command,
e.g. `28-020292457b98`, the following command would block for the time of the
temperature reading and return temperature at the sensor:

```tcl
set temp [onewire temperature 28-020292457b98]
```

As acquisition is blocking, it might be preferrable to schedule a command to be
called back with the temperature reading once it has finished. The following
example would print out the temperature value as it uses `puts` as its callback:

```tcl
onewire temperature 28-020292457b98 puts
```

### Continuous Measurements

It is also possible to bind a sensor to a variable so that periodical readings
will automatically set the variable to the value reported by the sensor. When
using this feature and interface, you should use fully-qualified variable names
to ensure that the library sets the proper variable in the proper namespace. The
following example would set the global variable called `temp` with the value of
the sensor every 10.2 seconds.

```tcl
onewire bind 28-020292457b98 ::temp 10.2
```
