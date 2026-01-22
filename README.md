# factory

Purpose: To generate a "Golden Image" (.img) file.

How to Run The Factory
Download OS: Get the official Orange Pi Ubuntu Server image. Rename it to orangepi.img and put it in scripts/.
Compile Code: In your Agent repo, run:
GOOS=linux GOARCH=arm64 go build -o agent
Put this agent binary in the root of structio-factory and rename it to agent_binary.
Run Scripts in Order:
code
Bash
cd scripts
./1_mount.sh
./2_install_deps.sh
./3_copy_agent.sh
./4_shrink.sh