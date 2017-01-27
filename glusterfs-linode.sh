#!/bin/bash

INFOMSG="$(tput bold)$(tput setaf 2)" # bright green
ERRMSG="$(tput bold)$(tput setaf 1)" # bright red
RESET="$(tput sgr0)"

setup() {
    
    local userid=$(id -u)
    if [ $userid -ne 0 ]; then
        errmsg "Please run with root privileges. Try prefixing with sudo."
        return 1
    fi
    
    if [ ! -f '/etc/os-release' ]; then
        errmsg "Unable to detect OS. Aborting. Please run setup on Ubuntu 14.04/16.04 or Debian 7/8 or CentOS 7"
        return 1
    fi
    
    local os_id=$(grep '^ID=' /etc/os-release | cut -d '=' -f2)
    local version_id=$(grep '^VERSION_ID=' /etc/os-release | cut -d '=' -f2)
    infomsg "Detected OS: $os_id $version_id"
    
    case $os_id in
        centos|'"centos"')
        setup_centos $version_id
        ;;
        
        ubuntu|'"ubuntu"')
        setup_ubuntu $version_id
        ;;

        debian|'"debian"')
        setup_debian $version_id
        ;;
        
        *)
        errmsg "Unable to setup in $os_id. Aborting. Please run setup on Ubuntu 14.04/16.04 or Debian 7/8 or CentOS 7"
        return 1
        ;;
    esac
    
    return $?
}

# $1 -> Version ID found in /etc/os-release. Enclosed in double quotes. Examples: "7" for CentOS 7
setup_centos() {
    infomsg "Installing EPEL repo"
    yum -y install epel-release
    yum -y updateinfo
    
    infomsg "Checking Python 2.7 installation"
    local tmp
    tmp=$(python -V)
    if [ $? -eq 0 ]; then
        infomsg "Python 2.7 is installed"
    else
        infomsg "Installing Python 2.7"
        yum -y install python2.7
    fi
    
    infomsg "Installing pip"
    yum -y install python-pip
    pip install --upgrade pip
    
    infomsg "Installing virtualenv"
    yum -y install python-virtualenv
    
    infomsg "Installing core utils"
    yum -y install unzip wget
    
    infomsg "Installing Ansible"
    yum install ansible
    
    # TODO Configure /etc/ansible/ansible.cfg - ControlPersist and pipelining
    
    infomsg "Installing HashiCorp Vault for storing API keys"
    wget -O vault.zip https://releases.hashicorp.com/vault/0.6.3/vault_0.6.3_linux_amd64.zip
    unzip vault.zip -d /usr/bin
    rm vault.zip
    
    infomsg "Installing Git"
    yum -y install git

    infomsg "Creating data directory"
    sudo -u $USERNAME mkdir -p clusters
    
    infomsg "Creating virtualenv"
    sudo -u $USERNAME virtualenv -p python2.7 glusenv
    
    infomsg "Activate virtualenv"
    source glusenv/bin/activate
    
    infomsg "Install python and SSL devel packages"
    yum -y install openssl-devel python-devel libffi-devel

    install_python_libraries()
    
    infomsg "Install gluster-linode Python scripts"
    git clone "https://github.com/pathbreak/glusterfs-linode"

    infomsg "Moving this script to ./glusterfs-linode/glusterfs-linode.sh"
    mv $0 ./glusterfs-linode
    
    infomsg "Installation Completed! Run GlusterFS management commands using ./glusterfs-linode/glusterfs-linode.sh"
}

# $1 -> Version ID found in /etc/os-release. Enclosed in double quotes. Examples: "14.04"
setup_ubuntu() {
    apt-get install software-properties-common

    infomsg "Install Ansible"
    apt-add-repository ppa:ansible/ansible
    apt-get update
    apt-get install ansible
    
    infomsg "Install python and SSL devel packages"
    apt-get install python-dev libffi-dev libssl-dev

    install_python_libraries()
}

# $1 -> Version ID found in /etc/os-release. Enclosed in double quotes. Examples: "8" for Debian 8
setup_debian() {
    infomsg "Install Ansible"
    echo 'deb http://ppa.launchpad.net/ansible/ansible/ubuntu trusty main' >> /etc/apt/sources.list
    apt-get update
    apt-get install ansible
    

}

install_python_libraries() {
    infomsg "Install Python libraries"
    pip install apache-libcloud hvac pyopenssl ndg-httpsclient pyasn1 linode-python \
        linode-api requests[security] passwordgen
}

infomsg() {
    printf "\n${INFOMSG}$1${RESET}\n"
}

errmsg() {
    printf "\n${ERRMSG}$1${RESET}\n"
}

case $1 in
    setup)
    setup
    ;;
    
    *)
    errmsg "Unknown command: $1"
    ;;
esac
