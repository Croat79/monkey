#!/bin/bash

WORKSPACE=${WORKSPACE:-$HOME}

APPDIR="$PWD/squashfs-root"
INSTALL_DIR="$APPDIR/usr/src"

GIT=$WORKSPACE/git

REPO_MONKEY_HOME=$GIT/monkey
REPO_MONKEY_SRC=$REPO_MONKEY_HOME/monkey

ISLAND_PATH="$INSTALL_DIR/monkey_island"
MONGO_PATH="$ISLAND_PATH/bin/mongodb"
ISLAND_BINARIES_PATH="$ISLAND_PATH/cc/binaries"

MONKEY_ORIGIN_URL="https://github.com/guardicore/monkey.git"
CONFIG_URL="https://raw.githubusercontent.com/guardicore/monkey/develop/deployment_scripts/config"
NODE_SRC=https://deb.nodesource.com/setup_12.x
APP_TOOL_URL=https://github.com/AppImage/AppImageKit/releases/download/12/appimagetool-x86_64.AppImage
PYTHON_VERSION="3.7.10"
PYTHON_APPIMAGE_URL="https://github.com/niess/python-appimage/releases/download/python3.7/python${PYTHON_VERSION}-cp37-cp37m-manylinux1_x86_64.AppImage"

is_root() {
  return "$(id -u)"
}

has_sudo() {
  # 0 true, 1 false
  sudo -nv > /dev/null 2>&1
  return $?
}

handle_error() {
  echo "Fix the errors above and rerun the script"
  exit 1
}

log_message() {
  echo -e "\n\n"
  echo -e "DEPLOYMENT SCRIPT: $1"
}

install_nodejs() {
  log_message "Installing nodejs"

  curl -sL $NODE_SRC | sudo -E bash -
  sudo apt-get install -y nodejs
}

install_build_prereqs() {
  sudo apt update
  sudo apt upgrade -y

  # monkey island prereqs
  sudo apt install -y curl libcurl4 openssl git build-essential moreutils
  install_nodejs
}

install_appimage_tool() {
  APP_TOOL_BIN=$WORKSPACE/bin/appimagetool

  mkdir -p "$WORKSPACE"/bin
  curl -L -o "$APP_TOOL_BIN" "$APP_TOOL_URL"
  chmod u+x "$APP_TOOL_BIN"

  PATH=$PATH:$WORKSPACE/bin
}

clone_monkey_repo() {
  if [[ ! -d ${GIT} ]]; then
    mkdir -p "${GIT}"
  fi

  log_message "Cloning files from git"
  branch=${1:-"develop"}
  git clone --single-branch --recurse-submodules -b "$branch" "$MONKEY_ORIGIN_URL" "$REPO_MONKEY_HOME" 2>&1 || handle_error
}

setup_appdir() {
  setup_python_37_appdir

  copy_monkey_island_to_appdir
  download_monkey_agent_binaries

  install_monkey_island_python_dependencies
  install_mongodb

  generate_ssl_cert
  build_frontend

  add_monkey_icon
  add_desktop_file
  add_apprun
}

setup_python_37_appdir() {
  PYTHON_APPIMAGE="python${PYTHON_VERSION}_x86_64.AppImage"
  rm -rf "$APPDIR" || true

  log_message "downloading Python3.7 Appimage"
  curl -L -o "$PYTHON_APPIMAGE" "$PYTHON_APPIMAGE_URL"

  chmod u+x "$PYTHON_APPIMAGE"

  ./"$PYTHON_APPIMAGE" --appimage-extract
  rm "$PYTHON_APPIMAGE"
  mkdir -p "$INSTALL_DIR"
}

copy_monkey_island_to_appdir() {
  cp "$REPO_MONKEY_SRC"/__init__.py "$INSTALL_DIR"
  cp "$REPO_MONKEY_SRC"/monkey_island.py "$INSTALL_DIR"
  cp -r "$REPO_MONKEY_SRC"/common "$INSTALL_DIR/"
  cp -r "$REPO_MONKEY_SRC"/monkey_island "$INSTALL_DIR/"
  cp ./run_appimage.sh "$INSTALL_DIR"/monkey_island/linux/
  cp ./island_logger_config.json "$INSTALL_DIR"/
  cp ./server_config.json.standard "$INSTALL_DIR"/monkey_island/cc/

  # TODO: This is a workaround that may be able to be removed after PR #848 is
  # merged. See monkey_island/cc/environment_singleton.py for more information.
  cp ./server_config.json.standard "$INSTALL_DIR"/monkey_island/cc/server_config.json
}

install_monkey_island_python_dependencies() {
  log_message "Installing island requirements"

  log_message "Installing pipenv"
  "$APPDIR"/AppRun -m pip install pipenv || handle_error

  requirements_island="$ISLAND_PATH/requirements.txt"
  generate_requirements_from_pipenv_lock $requirements_island

  log_message "Installing island python requirements"
  "$APPDIR"/AppRun -m pip install -r "${requirements_island}"  --ignore-installed || handle_error
}

generate_requirements_from_pipenv_lock () {
  log_message "Generating a requirements.txt file with 'pipenv lock -r'"
  cd $ISLAND_PATH
  "$APPDIR"/AppRun -m pipenv --python "$APPDIR/AppRun" lock -r > "$1" || handle_error
  cd -
}

download_monkey_agent_binaries() {
  log_message "Downloading monkey agent binaries to ${ISLAND_BINARIES_PATH}"

  load_monkey_binary_config

  mkdir -p "${ISLAND_BINARIES_PATH}" || handle_error
  curl -L -o "${ISLAND_BINARIES_PATH}/${LINUX_32_BINARY_NAME}" "${LINUX_32_BINARY_URL}"
  curl -L -o "${ISLAND_BINARIES_PATH}/${LINUX_64_BINARY_NAME}" "${LINUX_64_BINARY_URL}"
  curl -L -o "${ISLAND_BINARIES_PATH}/${WINDOWS_32_BINARY_NAME}" "${WINDOWS_32_BINARY_URL}"
  curl -L -o "${ISLAND_BINARIES_PATH}/${WINDOWS_64_BINARY_NAME}" "${WINDOWS_64_BINARY_URL}"

  # Allow them to be executed
  chmod a+x "$ISLAND_BINARIES_PATH/$LINUX_32_BINARY_NAME"
  chmod a+x "$ISLAND_BINARIES_PATH/$LINUX_64_BINARY_NAME"
}

load_monkey_binary_config() {
  tmpfile=$(mktemp)

  log_message "Downloading prebuilt binary configuration"
  curl -L -s -o "$tmpfile" "$CONFIG_URL"

  log_message "Loading configuration"
  source "$tmpfile"
}

install_mongodb() {
  log_message "Installing MongoDB"

  mkdir -p "$MONGO_PATH"
  "${ISLAND_PATH}"/linux/install_mongo.sh "${MONGO_PATH}" || handle_error
}

generate_ssl_cert() {
  log_message "Generating certificate"

  chmod u+x "${ISLAND_PATH}"/linux/create_certificate.sh
  "${ISLAND_PATH}"/linux/create_certificate.sh "${ISLAND_PATH}"/cc
}

build_frontend() {
  pushd "$ISLAND_PATH/cc/ui" || handle_error
  npm install sass-loader node-sass webpack --save-dev
  npm update

  log_message "Generating front end"
  npm run dist
  popd || handle_error

  remove_node_modules
}

remove_node_modules() {
  # Node has served its purpose. We don't need to deliver the node modules with
  # the AppImage.
  rm -rf "$ISLAND_PATH"/cc/ui/node_modules
}

add_monkey_icon() {
  unlink "$APPDIR"/python.png
  mkdir -p "$APPDIR"/usr/share/icons
  cp "$REPO_MONKEY_SRC"/monkey_island/cc/ui/src/images/monkey-icon.svg "$APPDIR"/usr/share/icons/infection-monkey.svg
  ln -s "$APPDIR"/usr/share/icons/infection-monkey.svg "$APPDIR"/infection-monkey.svg
}

add_desktop_file() {
  unlink "$APPDIR/python${PYTHON_VERSION}.desktop"
  cp ./infection-monkey.desktop "$APPDIR"/usr/share/applications
  ln -s "$APPDIR"/usr/share/applications/infection-monkey.desktop "$APPDIR"/infection-monkey.desktop
}

add_apprun() {
  cp ./AppRun "$APPDIR"
}

build_appimage() {
  log_message "Building AppImage"
  ARCH="x86_64" appimagetool "$APPDIR"
  apply_version_to_appimage "$1"
}

apply_version_to_appimage() {
  mv "Infection_Monkey-x86_64.AppImage" "Infection_Monkey-$1-x86_64.AppImage"
}

if is_root; then
  log_message "Please don't run this script as root"
  exit 1
fi

if ! has_sudo; then
  log_message "You need root permissions for some of this script operations. \
Run \`sudo -v\`, enter your password, and then re-run this script."
  exit 1
fi

monkey_version="dev"

while (( "$#" )); do
case "$1" in
  --version)
    if [ -n "$2" ] && [ "${2:0:1}" != "-" ]; then
      monkey_version=$2
      shift 2
    else
      echo "Error: Argument for $1 is missing" >&2
      exit 1
    fi
  esac
done


install_build_prereqs
install_appimage_tool

clone_monkey_repo "$@"

setup_appdir

build_appimage "$monkey_version"

log_message "Deployment script finished."
exit 0
