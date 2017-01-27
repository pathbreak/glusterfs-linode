'''
Module to create performance testing environment for Gluster clusters.
'''

import os
import os.path
import collections

from linode_core import Core, Linode
from provisioners import AnsibleProvisioner

import simplejson as json

import logger


def create_cluster(name, datacenter):
    
    test_cluster = load_cluster(name)
    if test_cluster is not None:
        print('Cluster %s already exists. Use a different name or load this one instead of creating.' % (name))
        return None
        
    cluster = collections.OrderedDict()
    cluster['name'] = name
    cluster['dc'] = datacenter
    cluster['servers'] = []
    cluster['clients'] = []
    
    save_cluster(cluster)
        
    return cluster
    

def add_client(name):
    
    cluster = load_cluster(name)
    
    '''
    Create a machine that acts as GlusterFS client
    and runs perf tests.
    '''
    # Create a linode
    app_ctx = {'conf-dir' : conf_dir()}
    core = Core(app_ctx)
    
    client_index = len(cluster['clients']) + 1
    
    label = 'perfclient-%d' % (client_index)
    client_linode_spec = {
            'plan_id' : 1,
            'datacenter' : cluster['dc'],
            'distribution' : 'Ubuntu 14.04 LTS',
            'kernel' : 'Latest 64 bit',
            'label' : label,
            'group' : 'perftests',
            #'disks' :   {
                            #'boot' : {'disk_size' : 19000},
                            #'swap' : {'disk_size' : 'auto'}
                        #}
            'disks' :   {
                            'boot' : {'disk_size' : 2.5*1024},
                            'swap' : {'disk_size' : 512},
                            'others' :  [
                                        {
                                            'label' : 'testhd',
                                            'disk_size' : 20 * 1024,
                                            'type' : 'xfs'
                                        }
                                        ]
                        }

    }
        
    linode = core.create_linode(client_linode_spec)
    if not linode:
        logger.error_msg('Could not create perf client')
        return
    
    # Save client details to cluster.
    client = collections.OrderedDict()
    client['id'] = linode.id
    client['public_ip'] = str(linode.public_ip[0])
    client['private_ip'] = linode.private_ip
    
    cluster['clients'].append(client)
    save_cluster(cluster)
    
    provision_client(cluster, client)




def provision_client(cluster, client):    
    print(cluster)
    print(client)
    
    # Provision it with glusterfs client, perf tools and monitoring tools.
    prov = AnsibleProvisioner()
    
    # Wait for SSH service on linode to come up.
    temp = Linode()
    temp.public_ip = [ client['public_ip'] ]
    if not prov.wait_for_ping(temp, 60, 10):
        print("Unable to reach %s over SSH" % (client['public_ip']))
        return
    
    pubkey_dir = os.path.join(conf_dir(), str(client['id'])) 
    if not os.path.exists(pubkey_dir):
        os.makedirs(pubkey_dir)
    
    print('Provisioning client')
    
    # Provision client's public key. Configure it to allow only key based
    # SSH. Provision cluster and perf tools on client.
    # This playbook also fetches client's public key and saves it in conf_dir/<LINODE_ID>/id_rsa.pub
    # While sending paths to ansible, always send absolute paths, because ansible's working 
    # directory is the directory in which the playbook resides, not the directory from which
    # the ansible-playbook is executed.
    prov.exec_playbook(client['public_ip'], 'ansible/perf_client.yaml',
        variables = {
            # If path does not end with a /, this becomes the name of the downloaded file
            # instead of the directory under which it should be saved.
            'pubkey_dir' : os.path.abspath(pubkey_dir + '/')
        })
    
    pubkey_file = os.path.join(pubkey_dir, 'id_rsa.pub')
    if os.path.isfile(pubkey_file):
        with open(pubkey_file, 'r') as f:
            pubkey = f.read().strip('\n')
            
        client['pubkey'] = pubkey
        save_cluster(cluster)
        
    else:
        print('Error: public key %s not found' % (pubkey_file))
    
    # Authorize client to access all other machines in cluster, and
    # vice versa.
    other_keys = [ c['pubkey'] for c in cluster['clients'][:-1] ]
    server_keys = [ s['pubkey'] for s in cluster['servers'] ]
    other_keys.extend(server_keys)
    
    if other_keys:
        add_auth_keys_to_client = '\n\n' + '\n'.join(other_keys) + '\n'
        
        print('Adding authorized keys')
        prov.exec_playbook(client['public_ip'], 'ansible/add_authorized_keys.yaml',
            variables = {
                'keys' : add_auth_keys_to_client
            })
        
        # Now add this client's key to all other machines.
        targets = [ c['public_ip'] for c in cluster['clients'][:-1] ]
        targets.extend( [ s['public_ip'] for s in cluster['servers'] ] )
        prov.exec_playbook(targets, 'ansible/add_authorized_keys.yaml',
            variables = {
                'keys' : client['pubkey'] + '\n'
            })
    
    
    
def add_server(name):
    
    cluster = load_cluster(name)
    
    '''
    Create a machine that acts as GlusterFS server and has some perf testing tools
    and scripts installed.
    '''
    # Create a linode
    app_ctx = {'conf-dir' : conf_dir()}
    core = Core(app_ctx)
    
    server_index = len(cluster['servers']) + 1
    
    label = 'perfserver-%d' % (server_index)
    server_linode_spec = {
            'plan_id' : 9,
            'datacenter' : cluster['dc'],
            'distribution' : 'Ubuntu 14.04 LTS',
            'kernel' : 'Latest 64 bit',
            'label' : label,
            'group' : 'perftests',
            # Plan 9 servers have 1152 GB of storage and 64 GB of RAM.
            # Allocate 10 GB for boot, 32 GB for swap, remaining 1110 GB for brick.
            'disks' :   {
                            'boot' : {'disk_size' : 10 * 1024},
                            'swap' : {'disk_size' : 32 * 1024},
                            'others' :  [
                                        {
                                            'label' : 'brick',
                                            'disk_size' : 1100 * 1024,
                                            'type' : 'xfs'
                                        }
                                        ]
                        }

    }
        
    linode = core.create_linode(server_linode_spec)
    if not linode:
        logger.error_msg('Could not create perf server')
        return
    
    # Save client details to cluster.
    server = collections.OrderedDict()
    server['id'] = linode.id
    server['public_ip'] = linode.public_ip[0]
    server['private_ip'] = linode.private_ip
    
    cluster['servers'].append(server)
    save_cluster(cluster)
    
    provision_server(cluster, server)



def provision_server(cluster, server):    
    
    # Provision it with glusterfs server, perf tools and monitoring tools.
    prov = AnsibleProvisioner()
    
    # Wait for SSH service on linode to come up.
    temp = Linode()
    temp.public_ip = [ server['public_ip'] ]
    prov.wait_for_ping(temp, 60, 10)
    
    pubkey_dir = os.path.join(conf_dir(), str(server['id'])) 
    if not os.path.exists(pubkey_dir):
        os.makedirs(pubkey_dir)
    
    print('Provisioning server')
    
    # Provision server's public key. Configure it to allow only key based
    # SSH. Provision cluster and perf tools on server.
    # This playbook also fetches client's public key and saves it in conf_dir/<LINODE_ID>/id_rsa.pub
    prov.exec_playbook(server['public_ip'], 'ansible/perf_server.yaml',
        variables = {
            # If path does not end with a /, this becomes the name of the downloaded file
            # instead of the directory under which it should be saved.
            'pubkey_dir' : os.path.abspath(pubkey_dir + '/')
        })
    
    pubkey_file = os.path.join(pubkey_dir, 'id_rsa.pub')
    if os.path.isfile(pubkey_file):
        with open(pubkey_file, 'r') as f:
            pubkey = f.read().strip('\n')
            
        server['pubkey'] = pubkey
        save_cluster(cluster)
        
    else:
        print('Error: publc key %s not found' % (pubkey_file))
    
    # When a new server is created, all existing clients should be able
    # to ssh to it. Other servers probably don't need to, but adding them
    # anyway.
    other_keys = [ s['pubkey'] for s in cluster['servers'][:-1] ]
    client_keys = [ c['pubkey'] for c in cluster['clients'] ]
    other_keys.extend(client_keys)
    
    if other_keys:
        
        print('Adding authorized keys')
        
        add_auth_keys_to_server = '\n\n' + '\n'.join(other_keys) + '\n'
        
        prov.exec_playbook(server['public_ip'], 'ansible/add_authorized_keys.yaml',
            variables = {
                'keys' : add_auth_keys_to_server
            })
        
        # Now add this client's key to all other machines.
        targets = [ s['public_ip'] for s in cluster['servers'][:-1] ]
        targets.extend( [ c['public_ip'] for c in cluster['clients'] ] )
        prov.exec_playbook(targets, 'ansible/add_authorized_keys.yaml',
            variables = {
                'keys' : server['pubkey'] + '\n'
            })
    
    
    


    
    
def load_cluster(name):
    
    the_conf_dir = conf_dir()
    cluster_file = os.path.join(the_conf_dir, name + '.json')
    if not os.path.isfile(cluster_file):
        return None

    with open(cluster_file, 'r') as f:
        cluster = json.load(f, object_pairs_hook=collections.OrderedDict)
    
    return cluster
    




def save_cluster(cluster):
    
    the_conf_dir = conf_dir()
    
    if not os.path.exists(the_conf_dir):
        os.makedirs(the_conf_dir)
    
    cluster_file = os.path.join(the_conf_dir, cluster['name'] + '.json')
    with open(cluster_file, 'w') as f:
        json.dump(cluster, f, indent = 4 * ' ')        
    
        
        
def conf_dir() :
    return './perfdata'
    
    
    
if __name__ == '__main__':
    
    name = 'perfcluster'
    #cluster = create_cluster(name, 6)
    cluster = load_cluster(name)
    #add_client(name)
    provision_client(cluster, cluster['clients'][-1])
    
    #add_server(name)
    #provision_server(cluster, cluster['servers'][-1])
    
    
