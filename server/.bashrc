# ~/.bashrc: executed by bash(1) for non-login shells.
# see /usr/share/doc/bash/examples/startup-files (in the package bash-doc)
# for examples

# If not running interactively, don't do anything
case $- in
    *i*) ;;
      *) return;;
esac

# don't put duplicate lines or lines starting with space in the history.
# See bash(1) for more options
HISTCONTROL=ignoreboth

# append to the history file, don't overwrite it
shopt -s histappend

# for setting history length see HISTSIZE and HISTFILESIZE in bash(1)
HISTSIZE=1000
HISTFILESIZE=2000

# check the window size after each command and, if necessary,
# update the values of LINES and COLUMNS.
shopt -s checkwinsize

# If set, the pattern "**" used in a pathname expansion context will
# match all files and zero or more directories and subdirectories.
#shopt -s globstar

# make less more friendly for non-text input files, see lesspipe(1)
[ -x /usr/bin/lesspipe ] && eval "$(SHELL=/bin/sh lesspipe)"

# set variable identifying the chroot you work in (used in the prompt below)
if [ -z "${debian_chroot:-}" ] && [ -r /etc/debian_chroot ]; then
    debian_chroot=$(cat /etc/debian_chroot)
fi

# set a fancy prompt (non-color, unless we know we "want" color)
case "$TERM" in
    xterm-color|*-256color) color_prompt=yes;;
esac

# uncomment for a colored prompt, if the terminal has the capability; turned
# off by default to not distract the user: the focus in a terminal window
# should be on the output of commands, not on the prompt
#force_color_prompt=yes

if [ -n "$force_color_prompt" ]; then
    if [ -x /usr/bin/tput ] && tput setaf 1 >&/dev/null; then
	# We have color support; assume it's compliant with Ecma-48
	# (ISO/IEC-6429). (Lack of such support is extremely rare, and such
	# a case would tend to support setf rather than setaf.)
	color_prompt=yes
    else
	color_prompt=
    fi
fi

if [ "$color_prompt" = yes ]; then
    PS1='${debian_chroot:+($debian_chroot)}\[\033[01;32m\]\u@\h\[\033[00m\]:\[\033[01;34m\]\w\[\033[00m\]\$ '
else
    PS1='${debian_chroot:+($debian_chroot)}\u@\h:\w\$ '
fi
unset color_prompt force_color_prompt

# If this is an xterm set the title to user@host:dir
case "$TERM" in
xterm*|rxvt*)
    PS1="\[\e]0;${debian_chroot:+($debian_chroot)}\u@\h: \w\a\]$PS1"
    ;;
*)
    ;;
esac

# enable color support of ls and also add handy aliases
if [ -x /usr/bin/dircolors ]; then
    test -r ~/.dircolors && eval "$(dircolors -b ~/.dircolors)" || eval "$(dircolors -b)"
    alias ls='ls --color=auto'
    #alias dir='dir --color=auto'
    #alias vdir='vdir --color=auto'

    alias grep='grep --color=auto'
    alias fgrep='fgrep --color=auto'
    alias egrep='egrep --color=auto'
fi

# colored GCC warnings and errors
#export GCC_COLORS='error=01;31:warning=01;35:note=01;36:caret=01;32:locus=01:quote=01'

# some more ls aliases
alias ll='ls -alF'
alias la='ls -A'
alias l='ls -CF'

# Add an "alert" alias for long running commands.  Use like so:
#   sleep 10; alert
alias alert='notify-send --urgency=low -i "$([ $? = 0 ] && echo terminal || echo error)" "$(history|tail -n1|sed -e '\''s/^\s*[0-9]\+\s*//;s/[;&|]\s*alert$//'\'')"'

# Alias definitions.
# You may want to put all your additions into a separate file like
# ~/.bash_aliases, instead of adding them here directly.
# See /usr/share/doc/bash-doc/examples in the bash-doc package.

if [ -f ~/.bash_aliases ]; then
    . ~/.bash_aliases
fi

# enable programmable completion features (you don't need to enable
# this, if it's already enabled in /etc/bash.bashrc and /etc/profile
# sources /etc/bash.bashrc).
if ! shopt -oq posix; then
  if [ -f /usr/share/bash-completion/bash_completion ]; then
    . /usr/share/bash-completion/bash_completion
  elif [ -f /etc/bash_completion ]; then
    . /etc/bash_completion
  fi
fi

# Variant 1: Shorter function name
rfu() {
    local folder_name
    folder_name=$(basename "$PWD")
    sudo -u "$folder_name" "$@"
}

# Variant 2: Shorter function name for 'bun run'
rbu() {
    local folder_name
    folder_name=$(basename "$PWD")
    sudo -u "$folder_name" bun run "$@"
}

create_and_clone_repo() {
    local service_name repo_name nice_service_name start_command working_dir user_name

    # Prompt for service name
    read -p "Enter the service name (default is current directory name): " service_name
    service_name=${service_name:-$(basename "$PWD")}

    # Prompt for the repository name (default is the service name)
    read -p "Enter the repository name (default is $service_name): " repo_name
    repo_name=${repo_name:-$service_name}

    # Prompt for a nice service description
    read -p "Enter a nice service description (default is '${service_name} Service'): " nice_service_name
    nice_service_name=${nice_service_name:-"${service_name} Service"}

    # Prompt for the start command (default is "/usr/local/bin/bun ./src/server.ts")
    read -p "Enter the start command (default is '/usr/local/bin/bun ./src/server.ts'): " start_command
    start_command=${start_command:-"/usr/local/bin/bun ./src/server.ts"}

    # Prompt for the working directory (default is "/srv/<service_name>")
    read -p "Enter the working directory (default is '/srv/${service_name}'): " working_dir
    working_dir=${working_dir:-"/srv/${service_name}"}

    # Prompt for the user name (default is the service name)
    read -p "Enter the user name (default is ${service_name}): " user_name
    user_name=${user_name:-$service_name}

    # Ensure the current directory is /srv
    if [[ "$PWD" != "/srv" ]]; then
        echo "Error: You need to be in the /srv directory to run this script."
        return 1
    fi

    # Create the user
    sudo adduser --system --no-create-home --group "$user_name"

    # Clone the repository
    sudo git clone "https://github.com/marcusta/${repo_name}.git" "$working_dir"

    # Change ownership of the cloned repository
    sudo chown -R "${user_name}:${user_name}" "$working_dir"

    # Create the systemd service file
    local service_file="/etc/systemd/system/${service_name}.service"
    sudo bash -c "cat > $service_file" <<EOL
[Unit]
Description=${nice_service_name}
After=network.target

[Service]
ExecStart=${start_command}
WorkingDirectory=${working_dir}
Restart=always
User=${user_name}
Group=${user_name}
Environment=NODE_ENV=production

[Install]
WantedBy=multi-user.target
EOL

    # Enable the systemd service
    sudo systemctl enable "${service_name}.service"

    # Print systemctl commands for managing the service
    echo "Systemd service ${service_name} created and enabled."
    echo "Use the following commands to manage the service:"
    echo "  Start: sudo systemctl start ${service_name}"
    echo "  Stop: sudo systemctl stop ${service_name}"
    echo "  Restart: sudo systemctl restart ${service_name}"

}

complete -F _command rfu
complete -F _command rbu
complete -F _command create_user_and_clone_repo
