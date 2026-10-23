SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
yum localinstall -y "${SCRIPT_DIR}/../../assets/docker/"*.rpm

