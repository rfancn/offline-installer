cp devtools.sh /usr/local/bin/devtools
chown root:root /usr/local/bin/devtools
chmod 755 /usr/local/bin/devtools

usermod -aG docker $USER
newgrp docker
