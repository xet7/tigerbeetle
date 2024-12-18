# Vortex Java Driver

This implements a driver for Vortex, using the Java client.

Run the following to test with this driver:

```
./zig/zig build -Drelease install
./zig/zig build -Drelease vortex
./zig/zig build clients:java -Drelease
(cd src/clients/java && mvn package)
(cd src/testing/vortex/java_driver && mvn package)
CLASS_PATH="src/clients/java/target/tigerbeetle-java-0.0.1-SNAPSHOT.jar"
CLASS_PATH="${CLASS_PATH}:src/testing/vortex/java_driver/target/driver-0.0.1-SNAPSHOT.jar"
unshare --net --fork --map-root-user --pid bash -c "
    ip link set up dev lo ; 
    zig-out/bin/vortex supervisor \
        --tigerbeetle-executable=./zig-out/bin/tigerbeetle \
        --test-duration-minutes=10 \
        --driver-command=java\ -cp\ $CLASS_PATH\ Main
    "
```
