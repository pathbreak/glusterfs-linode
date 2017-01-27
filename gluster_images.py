from image_manager import Image, ImageManager
from provisioners import AnsibleProvisioner
import linode_core

import sys

import logger

class GlusterImages(object):
    
    def __init__(self, app_ctx):
        self.app_ctx = app_ctx
        
        
        
    def create_gluster_image(self, image_label, image_spec, delete_on_error = True):
        
        img_mgr = ImageManager(self.app_ctx)
        
        # TODO these should be read from a JSON file.
        img = Image(image_label, 'linode', image_spec)
        
        gluster_image_provisioner = GlusterImageProvisioner()
        img_mgr.create_image(img, gluster_image_provisioner, delete_on_error)
        


class  GlusterImageProvisioner(AnsibleProvisioner):
    
    def provision(self, linode):
        
        logger.msg('Provisioning Gluster on %s' % (linode.public_ip[0]))
        output = self.exec_playbook(linode.public_ip[0], 'ansible/gluster_install.yaml')
        
        # TODO Detect if provisioning failed and return False on error
        
        return True
    

if __name__ == '__main__':
    
    image_label = sys.argv[1]
    
    gluser_img = GlusterImages({'conf-dir' : 'glusterdata'})
    
    gluser_img.create_gluster_image(image_label, 
        {
            'datacenter' : 'singapore',
            'distribution' : 'Ubuntu 14.04 LTS',
            'kernel' : 'Latest 64 bit',
            'type' : 'linode-image',
            'cluster-type' : 'gluster'
                
        }, delete_on_error = True)

    
    #provisioner = AnsibleProvisioner()
    #output = provisioner.exec_playbook('139.162.57.76', 'ansible/gluster_install.yaml')
    
    '''    
    provisioner = GlusterImageProvisioner()
    linode = linode_core.Core({'conf-dir':''})
    linode.public_ip = ['139.162.9.151']
    provisioner.ping(linode)
    '''




