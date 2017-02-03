============================================================================

CAUTION:  THIS IS STILL  A WORK IN PROGRESS AND IS NOT YET PRODUCTION READY.
FOLLOW THIS REPO TO BE NOTIFIED WHEN THERE'S A RELEASE VERSION.
THANK YOU FOR YOUR INTEREST!

============================================================================

## Installation

### Create the administration Linode

**Note**: If you already have an existing Linode or other machine and it's reachable from the Internet, you can use that machine instead of creating a new Linode. Specifically, it should be reachable at its public IP address and ports 4505-4506. If it's behind a NAT or firewall, it's probably not reachable there without some system administration changes.

Create a Linode by following the steps in [Getting Started with Linode](https://www.linode.com/docs/getting-started). 
A Linode 2048 in any data center will do.

Secure the Linode by following [Securing Your Server](https://www.linode.com/docs/security/securing-your-server).

Open an SSH session to the Linode.

### Install Git

#### Debian / Ubuntu:

    sudo apt-get install git

#### CentOS:

    sudo yum install git
    
    
### Download `glusterfs-linode` software
    
    git clone https://github.com/pathbreak/glusterfs-linode
    
    
### Run the setup

Run the setup script with root privileges. You may be asked to enter your `sudo` password.

    cd glusterfs-linode
    sudo bash ./glusterfs-linode.sh setup

