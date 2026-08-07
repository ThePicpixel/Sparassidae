
sudo zypper in podman podman-docker docker-compose

systemctl --user enable --now podman.socket

sudo mkdir -p /etc/systemd/system/user@$(id -u).service.d
printf '[Service]\nLimitMEMLOCK=infinity\n' | sudo tee \
  /etc/systemd/system/user@$(id -u).service.d/memlock.conf
printf '[Service]\nDelegate=cpu cpuset io memory pids\n' | sudo tee \
  /etc/systemd/system/user@$(id -u).service.d/delegate.conf

sudo systemctl daemon-reload && loginctl terminate-user $(id -un)
