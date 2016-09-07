#!/bin/bash
#/ Usage: bin/strap.sh [--debug]
#/ Install development dependencies on Mac OS X.
set -e

# Keep sudo timestamp updated while Strap is running.
if [ "$1" = "--sudo-wait" ]; then
  while true; do
    mkdir -p "/var/db/sudo/$SUDO_USER"
    touch "/var/db/sudo/$SUDO_USER"
    sleep 1
  done
  exit 0
fi

[ "$1" = "--debug" ] && STRAP_DEBUG="1"
STRAP_SUCCESS=""

cleanup() {
  set +e
  if [ -n "$STRAP_SUDO_WAIT_PID" ]; then
    sudo kill "$STRAP_SUDO_WAIT_PID"
  fi
  sudo -k
  rm -f "$CLT_PLACEHOLDER"
  if [ -z "$STRAP_SUCCESS" ]; then
    if [ -n "$STRAP_STEP" ]; then
      echo "!!! $STRAP_STEP FAILED" >&2
    else
      echo "!!! FAILED" >&2
    fi
    if [ -z "$STRAP_DEBUG" ]; then
      echo "!!! Run '$0 --debug' for debugging output." >&2
      echo "!!! If you're stuck: file an issue with debugging output at:" >&2
      echo "!!!   $STRAP_ISSUES_URL" >&2
    fi
  fi
}

trap "cleanup" EXIT

if [ -n "$STRAP_DEBUG" ]; then
  set -x
else
  STRAP_QUIET_FLAG="-q"
  Q="$STRAP_QUIET_FLAG"
fi


json_value() { # jq won't be available the first time
    JSON=$1
    KEY=$2
    echo $JSON | python -c 'import sys, json; print json.load(sys.stdin)[sys.argv[1]]' $KEY 2>/dev/null || true
}

STDIN_FILE_DESCRIPTOR="0"
[ -t "$STDIN_FILE_DESCRIPTOR" ] && STRAP_INTERACTIVE="1"

# STRAP_GITHUB_USER="MeddahJ"
# STRAP_GITHUB_TOKEN="4dd79300a0cf7317ef8fdfb8c75cd0fdd69cecf5"
STRAP_ISSUES_URL="https://github.com/MeddahJ/strap/issues/new"

STRAP_FULL_PATH="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"

github_authentication () {
    USER=$1
    PASSWORD=$2
    TFA_CODE=$3

    curl -s -u "$USER:$PASSWORD" `[[ -n $TFA_CODE ]] && echo "-H \"X-GitHub-OTP:$TFA_CODE\""` "https://api.github.com/authorizations" -d "{
      \"scopes\": [
        \"write:public_key\",
        \"user:email\",
        \"repo\"
      ],
      \"note\": \"$USER@$(hostname -s) on $(date)\"
    }"
}

if [ -z "$STRAP_GITHUB_USER" ] || [ -z "$STRAP_GITHUB_TOKEN" ] ; then
    echo -n "Github Username:"
    read STRAP_GITHUB_USER

    echo -n "Github Password:"
    read -s STRAP_GITHUB_PASSWORD
    echo

    AUTH_RESPONSE=$(github_authentication $STRAP_GITHUB_USER $STRAP_GITHUB_PASSWORD)

    MESSAGE=`json_value "$AUTH_RESPONSE" message`

    echo "$AUTH_RESPONSE"

    if [ "$MESSAGE" = "Bad credentials" ]
    then
        echo "Invalid credentials for user $STRAP_GITHUB_USER"
        exit 1
    elif [ "$MESSAGE" = "Must specify two-factor authentication OTP code." ]
    then
        echo -n "GitHub two-factor authentication code:"
        read -s STRAP_GITHUB_2FA_CODE
        echo

        AUTH_RESPONSE=$(github_authentication $STRAP_GITHUB_USER $STRAP_GITHUB_PASSWORD $STRAP_GITHUB_2FA_CODE)

        MESSAGE=`json_value "$AUTH_RESPONSE" message`

        # if [ "$MESSAGE" = "Bad credentials" ] #todo: while loop
        if [ "$MESSAGE" = "Must specify two-factor authentication OTP code." ]
        then
            echo "Invalid 2FA code for user $STRAP_GITHUB_USER"
            exit 1
        fi
    fi

    unset STRAP_GITHUB_PASSWORD
    unset STRAP_GITHUB_2FA_CODE

    # echo $AUTH_RESPONSE
    STRAP_GITHUB_TOKEN=`json_value "$AUTH_RESPONSE" token`

    echo $STRAP_GITHUB_TOKEN

fi

# # Todo: rm public key token with exact name if exists

PRIVATE_KEY_PATH=github_rsa

rm -f $PRIVATE_KEY_PATH $PRIVATE_KEY_PATH.pub

ssh-keygen -t rsa -b 4096 -C "github.com/$STRAP_GITHUB_USER" -N "" -f ./$PRIVATE_KEY_PATH -q

curl -s -u "$STRAP_GITHUB_USER:$STRAP_GITHUB_TOKEN" "https://api.github.com/user/keys" -d "{
  \"title\": \"$STRAP_GITHUB_USER@`hostname -s`\",
  \"key\": \"`cat $PRIVATE_KEY_PATH.pub`\"
}"

echo "Public key added to credentials"




abort() { STRAP_STEP="";   echo "!!! $*" >&2; exit 1; }
log()   { STRAP_STEP="$*"; echo "--> $*"; }
logn()  { STRAP_STEP="$*"; printf -- "--> $* "; }
logk()  { STRAP_STEP="";   echo "OK"; }

sw_vers -productVersion | grep $Q -E "^10.(9|10|11|12)" || abort "Run Strap on Mac OS X 10.9/10/11/12."

[ "$USER" = "root" ] && abort "Run Strap as yourself, not root."
# groups | grep $Q admin || abort "Add $USER to the admin group."


IS_ADMIN="`groups | grep admin | wc -l`"

# STRAP_SUCCESS="1"
# exit 0


function when_admin() {
    # Initialise sudo now to save prompting later.
    log "Enter your password (for sudo access):"
    sudo -k
    sudo /usr/bin/true
    [ -f "$STRAP_FULL_PATH" ]
    sudo bash "$STRAP_FULL_PATH" --sudo-wait &
    STRAP_SUDO_WAIT_PID="$!"
    ps -p "$STRAP_SUDO_WAIT_PID" &>/dev/null
    logk

    # Check and enable full-disk encryption.
    logn "Checking full-disk encryption status:"
    if fdesetup status | grep $Q -E "FileVault is (On|Off, but will be enabled after the next restart)."; then
      logk
    elif [ -n "$STRAP_INTERACTIVE" ]; then
      echo
      log "Enabling full-disk encryption on next reboot:"
      sudo fdesetup enable -user "$USER" \
        | tee ~/Desktop/"FileVault Recovery Key.txt"
      logk
    else
      echo
      abort "Run 'sudo fdesetup enable -user \"$USER\"' to enable full-disk encryption."
    fi


    # Install the Xcode Command Line Tools.
    DEVELOPER_DIR=$("xcode-select" -print-path 2>/dev/null || true)
    [ -z "$DEVELOPER_DIR" ] || ! [ -f "$DEVELOPER_DIR/usr/bin/git" ] \
                            || ! [ -f "/usr/include/iconv.h" ] && {
      log "Installing the Xcode Command Line Tools:"
      CLT_PLACEHOLDER="/tmp/.com.apple.dt.CommandLineTools.installondemand.in-progress"
      sudo touch "$CLT_PLACEHOLDER"
      CLT_PACKAGE=$(softwareupdate -l | \
                    grep -B 1 -E "Command Line (Developer|Tools)" | \
                    awk -F"*" '/^ +\*/ {print $2}' | sed 's/^ *//' | head -n1)
      sudo softwareupdate -i "$CLT_PACKAGE"
      sudo rm -f "$CLT_PLACEHOLDER"
      if ! [ -f "/usr/include/iconv.h" ]; then
        if [ -n "$STRAP_INTERACTIVE" ]; then
          echo
          logn "Requesting user install of Xcode Command Line Tools:"
          xcode-select --install
        else
          echo
          abort "Run 'xcode-select --install' to install the Xcode Command Line Tools."
        fi
      fi
      logk
    }

    # Check if the Xcode license is agreed to and agree if not.
    xcode_license() {
      if /usr/bin/xcrun clang 2>&1 | grep $Q license; then
        if [ -n "$STRAP_INTERACTIVE" ]; then
          logn "Asking for Xcode license confirmation:"
          sudo xcodebuild -license
          logk
        else
          abort "Run 'sudo xcodebuild -license' to agree to the Xcode license."
        fi
      fi
    }
    xcode_license
}

[ $IS_ADMIN = 1 ] && when_admin

# Belongs in .gitconfig
#
# # Setup Git configuration.
# logn "Configuring Git:"
# if [ -n "$STRAP_GIT_NAME" ] && ! git config user.name >/dev/null; then
#   git config --global user.name "$STRAP_GIT_NAME"
# fi
#
# if [ -n "$STRAP_GIT_EMAIL" ] && ! git config user.email >/dev/null; then
#   git config --global user.email "$STRAP_GIT_EMAIL"
# fi
#
# if [ -n "$STRAP_GITHUB_USER" ] && [ "$(git config --global github.user)" != "$STRAP_GITHUB_USER" ]; then
#   git config --global github.user "$STRAP_GITHUB_USER"
# fi
#
# # Squelch git 2.x warning message when pushing
# if ! git config push.default >/dev/null; then
#   git config --global push.default simple
# fi

# Setup GitHub HTTPS credentials.
if git credential-osxkeychain 2>&1 | grep $Q "git.credential-osxkeychain"
then
  if [ "$(git config --global credential.helper)" != "osxkeychain" ]
  then
    git config --global credential.helper osxkeychain
  fi

  if [ -n "$STRAP_GITHUB_USER" ] && [ -n "$STRAP_GITHUB_TOKEN" ]
  then
    printf "protocol=https\nhost=github.com\n" | git credential-osxkeychain erase
    printf "protocol=https\nhost=github.com\nusername=%s\npassword=%s\n" \
          "$STRAP_GITHUB_USER" "$STRAP_GITHUB_TOKEN" \
          | git credential-osxkeychain store
  fi
fi
logk

if ! [[ -x `which brew` ]] ; then
    # Setup Homebrew directory and permissions.
    logn "Installing Homebrew:"

    [ $IS_ADMIN = 1 ] && HOMEBREW_PREFIX="/usr/local" || HOMEBREW_PREFIX="$HOME/.homebrew"

    [ -d "$HOMEBREW_PREFIX" ] || sudo mkdir -p "$HOMEBREW_PREFIX"
    [ $IS_ADMIN = 1 ] && sudo chown -R "$USER:admin" "$HOMEBREW_PREFIX"

    # Download Homebrew.
    export GIT_DIR="$HOMEBREW_PREFIX/.git" GIT_WORK_TREE="$HOMEBREW_PREFIX"
    git init $Q
    git config remote.origin.url "https://github.com/Homebrew/brew"
    git config remote.origin.fetch "+refs/heads/*:refs/remotes/origin/*"
    git fetch $Q --no-tags --depth=1 --force --update-shallow
    git reset $Q --hard origin/master
    unset GIT_DIR GIT_WORK_TREE
    logk
    export PATH="$HOMEBREW_PREFIX/bin:$PATH"
fi

# Update Homebrew.
log "Updating Homebrew:"
brew update
logk



# Install from local Brewfile
if [ -f "$HOME/.Brewfile" ]; then
  log "Installing from user Brewfile on GitHub:"
  brew bundle --global
  logk
fi

if ! [ -d "$HOME/.library" ] ; then
  git clone git@github.com:MeddahJ/osx-library.git "$HOME/.library"
  rsync -a "$HOME/.library" "$HOME/Library"
else
  git pull origin master
  # TODO: implement automatic sync between library files
fi


if ! [ -d "$HOME/.dotfiles" ] ; then
  git clone git@github.com:MeddahJ/dotfiles.git "$HOME/.dotfiles"
else
  git pull origin master
  # TODO: implement automatic sync between library files
fi
ls -d "$HOME/.dotfiles/.*" | xargs -I dotfile ln -fs dotfile $HOME/dotfile



if [ $IS_ADMIN = 1 ] ; then
    # Check and install any remaining software updates.
    logn "Checking for software updates:"
    if softwareupdate -l 2>&1 | grep $Q "No new software available."; then
      logk
    else
      echo
      log "Installing software updates:"

        sudo softwareupdate -l | grep "*" -A1 | sed -e'2N;$!N;/\n.*restart.*/!P;D' | sed -n "s/^.*\* //p" | xargs -I app softwareupdate -i "app"
        #   sudo softwareupdate --install --all
        xcode_license
      logk
    fi
fi

STRAP_SUCCESS="1"
log "Bootstrap done"
