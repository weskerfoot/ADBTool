### ADBWatch

A tool to play with the Android Debug Bridge protocol, and do useful things on your Android phone. This is a re-implementation of the clientside part of the ADB wire protocol, with some hopefully useful added functions.

A few things are possible right now:
* It can run arbitrary shell commands
* A reimplementation of all of the ADB sync protocol (file transfer)
* Reboot the phone
* List all CA certificates

Goals:
* Ability to safely install a custom CA certificate on your phone, and revoke it.
* Reverse proxying / MITM your phone.
* Create a backup of everything accessible (requires root for everything).

### Building
Simply install `nim` and `nimble` and run `nimble build` to get the binary.
