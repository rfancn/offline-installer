SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
dpkg -i "${SCRIPT_DIR}/../../assets/nfs/"*.deb
