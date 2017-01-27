import re
import os
import collections

import simplejson as json
from simplejson.scanner import JSONDecodeError

import linode_api as lin
import linode_core
import image_manager

from provisioners import AnsibleProvisioner

import dpath.util as dp

import logger

from pprint import pprint

class GlusterClusterPlan(object):
    
    
    def __init__(self, app_ctx, cluster_label):
        self.validated = False
        self.current_schema_version = 1
        
        self.app_ctx = app_ctx
        
        self.cluster_label = cluster_label
        
        # In the plan, user needs some way to refer to nodes before they've been created, to
        # specify things like "create a volume over 1st node  and 3rd node".
        #
        # We enable this by giving 2 indexes to every node - a "global node index" that is unique
        # for every node regardless of plan, and a "plan node index" that is unique 
        # only among nodes of the same plan.
        self.global_node_index = 1
        
        assert LinodeStaticInfo.ids is not None and len(LinodeStaticInfo.ids) > 0
        self.plan_node_indexes = {}
        for plan_id in LinodeStaticInfo.ids:
            self.plan_node_indexes[plan_id] = 1
        
        # Plan IDs for all the plan specifications encountered in the plan file are
        # cached here to avoid multiple processing. Just a perf optimization.
        self.plan_id_cache = {}
        
        
    
    
    def load_from_json(self, filepath):
        
        try:
            with open(filepath, 'r') as f:
                # object_pairs_hook and object_hook ensure that data is retained
                # in the same order as the file. Keeps it readable when written back.
                self.plan = json.load(f, 
                    object_pairs_hook = collections.OrderedDict, 
                    object_hook = collections.OrderedDict)
            
            # TODO If version is not current schema version, the file
            # should be upgraded
                
            validated = self.validate()
            
            if not validated:
                logger.error_msg("%s is not a valid JSON cluster plan file" % (filepath))
                return False
                
            return True
            
        except JSONDecodeError as e:
            logger.error_msg(str(e))
            return False
            
            
    
    def create(self):
        #TODO assert self.validated
        
        # Lock the plan to prevent concurrent modifications.
        
        dc = dp.get(self.plan, 'cluster-plan/datacenter')
        dc_id = LinodeStaticInfo.dc_id(dc)
        
        cluster_plan = dp.get(self.plan, 'cluster-plan')
        
        image_label = cluster_plan['image']
        img_mgr = image_manager.ImageManager(self.app_ctx)
        image = img_mgr.load_image(image_label)
        
        # Each node plan has its own storage plan.
        # Read and cache all the storage plans.
        storage_plans = {}
        
        # Each node plan has its own set of bricks and each brick
        # specifies where it should be mounted. Store this information
        # now because it's required for provisioning the nodes later on.
        # The dict is plan_id -> list of brick mounts.
        brick_mounts = {}
        
        block_device_names = ['sda', 'sdb', 'sdc', 'sdd', 'sde', 'sdf', 'sdg', 'sdh']
        
        for item in cluster_plan['storage']:
            # TODO Cache and validate
            plan_id = self._get_plan_id(item['plan'])
            disks = item['disks']
            
            disk_plan = {}
            
            # An index into the block device names above. We need it to know
            # the correct block device of a brick. Since it can change based
            # on optional disks like swap disk, we track it using an index.
            # 'block_device_names[dev_idx]' gives the block device name for
            # next disk to be created.
            dev_idx = 0
            
            boot_disk = disks.get('boot')
            if boot_disk:
                size_in_mb = self._disk_size_in_mb(boot_disk['size'])
                disk_plan['boot'] = {'disk_size' : size_in_mb}    
                dev_idx += 1
                
            swap_disk = disks.get('swap')
            if swap_disk:
                size_in_mb = swap_disk['size']
                if type(size_in_mb) == int:
                    size_in_mb = self._disk_size_in_mb(size_in_mb)
                else:
                    if size_in_mb != 'auto':
                        size_in_mb = int(size_in_mb)
                    
                disk_plan['swap'] = {'disk_size' : size_in_mb}
                dev_idx += 1
                
            bricks = disks.get('bricks')
            brick_mounts[plan_id] = []
            if bricks:
                other_disks = []
                for brick in bricks:
                    size_in_mb = self._disk_size_in_mb(brick['size'])
                    other_disks.append({
                        'label' : brick['label'],
                        'disk_size' : size_in_mb,
                        'type' : brick['type']
                    })
                    brick_mounts[plan_id].append({
                        'device' : '/dev/' + block_device_names[dev_idx],
                        'mount' : brick['mount'],
                        'fs' : brick['type']
                    })
                    dev_idx += 1
                    
                disk_plan['others'] = other_disks
                
            
            storage_plans[plan_id] = disk_plan
        
            
        core = linode_core.Core(self.app_ctx)
        
        # Store details of created Linodes in this list, with nodes grouped by plan_id
        node_list = {}
        
        # Create nodes based on node plan.
        for item in cluster_plan['nodes']:
            
            # plan to plan id must already be cached earlier by validate
            plan = item['plan']
            plan_id = self.plan_id_cache.get(plan)
            assert plan_id is not None
            if plan_id is None:
                plan_id = self._get_plan_id(plan)
            
            count = item['count']
            
            node_list[plan_id] = []
            
            for i in range(count):
                
                linode_spec = {
                    'plan_id' : plan_id,
                    'datacenter' : dc_id,
                    'image' : image_label,
                    'kernel' : image.spec['kernel'],
                    'label' : 'gluster-{linode_id}',
                    'group' : self.cluster_label,
                    'disks' :  storage_plans[plan_id]
                }
                
                logger.msg('\nCreating node #%d in cluster, #%d in plan %d' % (self.global_node_index,
                    self.plan_node_indexes[plan_id], plan_id))
                    
                node_info = core.create_linode(linode_spec)
                if node_info:
                    node_info.global_index = self.global_node_index
                    node_info.plan_index = self.plan_node_indexes[plan_id]
                    
                    node_list[plan_id].append(node_info)
                
                self.plan_node_indexes[plan_id] += 1
                self.global_node_index += 1
        
        # Store details of created nodes.
        # TODO I think other details like brick mount on each node too should be saved here. Also, since objects are 
        # not JSON serializable by default, look into replacing Linode object with plain dicts.
        
        cluster_info_dir = os.path.join(self.app_ctx['conf-dir'], 'clusters', self.cluster_label)
        os.makedirs(cluster_info_dir)
        cluster_info_filename = os.path.join(cluster_info_dir, 'cluster.json')
        with open(cluster_info_filename, 'w') as f:
            # Since objects are not JSON serializable, we tell simplejson to extract their __dict__ attributes
            # and serialize that.
            json.dump(node_list, f, indent = 4 * ' ', default=lambda o:o.__dict__)
        
        # TODO configure hostnames, FQDNs, DNS related stuff, etc.
        
        # Create filesystems on nodes which have non-ext bricks.
        # TODO https://www.gluster.org/pipermail/gluster-users/2013-March/012697.html suggests creating XFS
        # with inode size to 512 .
        brickfs_provisioner = BrickFilesystemsProvisioner()
        brickfs_provisioner.provision_brick_filesystems(node_list, brick_mounts)
        
        # Mount bricks on all nodes.
        brickmounts_provisioner = BrickMountsProvisioner()
        brickmounts_provisioner.provision_brick_mounts(node_list, brick_mounts)
        
        # TODO volume provisioning
        
        
    
    
    def validate(self):
        '''
        Validate the cluster plan.
        
        Returns:
            (valid, errors) - Tuple. 'valid' is a boolean. errors is a list of error messages if it's invalid
                or None if valid.
        '''
        dv = DictValidator(self.plan)
        
        dv.assert_int('schema-version')
        dv.assert_value('cluster-type', 'gluster')
        
        if not dv.assert_exists('cluster-plan'):
            # Can't continue any more since the root element itself is missing.
            return (False, dv.errors)

        if dv.assert_exists('cluster-plan/datacenter'):
            dc = dp.get(self.plan, 'cluster-plan/datacenter')
            dc_id = LinodeStaticInfo.dc_id(dc)
            if dc_id is None:
                dv.add_error('Invalid datacenter: %s' % (dc))
        
        if not dv.assert_exists('cluster-plan/nodes'):
            # Can't continue any more since the root element itself is missing.
            return (False, dv.errors)
             
        nodes = dp.get(self.plan, 'cluster-plan/nodes')
        if len(nodes) == 0:
            # Can't continue any more since the root element itself is missing.
            dv.add_error("'nodes' is empty")
            return (False, dv.errors)
            
        for i, item in enumerate(nodes):
            plan = item.get('plan', None)
            if plan is None:
                dv.add_error("Error in nodes child #%d: 'plan' missing" % (i+1))
            else:
                try:
                    plan_id = self._get_plan_id(plan)
                    self.plan_id_cache[item['plan']] = plan_id
                    
                except ValueError as e:
                    dv.add_error('Error in nodes child #%d: %s' % (i+1, e.message))
            

            count = item.get('count', 0)
            if type(count) is not int:
                dv.add_error('Error in nodes child #%d: count should be an integer')
            if count == 0:
                dv.add_error("Error in nodes child #%d: count is missing or 0")
                
        # TODO Validate storage plan
        # TODO Validate that each node plan has corresponding storage plan
        # TODO Validate filesystems and sizes in storage plan
        # TODO Validate that plan ID data are not duplicated.
        # TODO Validate that each storage plan has max 8 disks
        # TODO Validate that mount points in same plan are not duplicated
        
        self.validated = dv.is_valid()
        return (True, None)


    def _get_plan_id(self, plan):
        ''' 
        Gets the correct Linode plan ID for specified plan.
        
        Args:
            - plan : a string with the syntax '<selector>:<value>'. 
                examples - 'label:Linode 2048' or 'id:2' or 'disk:48GB' or 'disk:48 GB'
                
        Returns:
            the plan ID as an integer
        '''
        
        tokens = plan.split(':')
        if len(tokens) != 2:
            raise ValueError("Invalid plan: '%s'" % (plan))
            
        tokens[0] = tokens[0].strip()
        tokens[1] = tokens[1].strip()
        
        if tokens[0] == 'id':
            plan_id = int(tokens[1])
            if not LinodeStaticInfo.is_valid_id(plan_id):
                raise ValueError("Invalid plan id: '%s'" % (plan))
                
        elif tokens[0] == 'label':
            plan_id = LinodeStaticInfo.id_from_label(tokens[1])
            
            if plan_id is None:
                raise ValueError("Invalid plan label: '%s'" % (plan))
                
        elif tokens[0] == 'disk':
            
            m = re.match('([0-9]+)(.*)', tokens[1])
            if not m:
                raise ValueError("Invalid plan disk: '%s'" % (plan))
            
            storage = int(m.groups()[0])
            units = m.groups()[1].strip()
            
            if units and units != 'GB':
                raise ValueError("Invalid plan disk units: '%s'" % (plan))
            
            plan_id = LinodeStaticInfo.id_from_storage(storage)
            
            if plan_id is None:
                raise ValueError("Invalid plan disk: '%s'" % (plan))
                
        
        return plan_id
        
        
    def _disk_size_in_mb(self, size):
        '''
        Converts a human readable disk size like "1TB" or "5 GB" to numerical 
        size in MB.
        
        Args:
            - size : a number like 100000 of a string like '48GB' or '1.2 TB'
                
        Returns:
            integer size in MB
        '''
        if type(size) == int:
            return size
        
        m = re.match('([0-9]*[\.]?[0-9]*)[\s]*([mMgGtT]{1,1}[bB])', size)
        if m:
            val = m.groups()[0]
            unit = m.groups()[1].lower()
            
            if not val:
                raise ValueError("Invalid disk size. Should be '<number> MB|GB|TB': '%s'" % (size))
                
            val = float(val)
            if unit == 'mb':
                val = int(val)
                
            elif unit == 'gb':
                val = int(val * 1024)
                
            elif unit == 'tb':
                val = int(val * 1024 * 1024)
            
            return val
        else:
            raise ValueError("Invalid disk size. Should be '<number> MB|GB|TB': '%s'" % (size))


class BrickMountsProvisioner(object):
    
    def provision_brick_mounts(self, node_list, brick_mounts):
        provisioner = AnsibleProvisioner()
        
        # Since all nodes of same plan have the same mounts, we provision
        # all nodes of same plan in a batch.
        for plan_id, nodes_of_plan in node_list.iteritems():
            mounts_for_plan = brick_mounts[plan_id]
            
            targets = [n.public_ip[0] for n in nodes_of_plan]
            
            logger.msg("Mounts: %s\nTargets: %s" % (mounts_for_plan, targets))
            
            provisioner.exec_playbook(targets, 'ansible/mount_bricks.yaml', 
                variables = {'mounts':mounts_for_plan})

 
                
class BrickFilesystemsProvisioner(object):
    
    def provision_brick_filesystems(self, node_list, brick_mounts):
        provisioner = AnsibleProvisioner()
        
        # Not all nodes need filesystem provisioning. Only nodes having
        # bricks with FS which are not ext4 require it.
        # We need to define an ansible variable "filesystems" as a list of 
        # {'fs':'<filesystem>,'device':'<blockdevice>'} dicts.
        # for each set of nodes of same plan and requring non-ext4 filesystems.
        for plan_id, bricks_for_plan in brick_mounts.iteritems():
            filesystems = []
            
            for brick in bricks_for_plan:
                if brick['fs'].lower() not in ['ext4', 'ext3']:
                    filesystems.append( {'fs':brick['fs'], 'device':brick['device'] } )
            
            if len(filesystems) > 0:
                nodes_of_plan = node_list[plan_id]
                
                targets = [n.public_ip[0] for n in nodes_of_plan]

                logger.msg("Filesystems: %s\nTargets: %s" % (filesystems, targets))
                
                provisioner.exec_playbook(targets, 'ansible/create_filesystems.yaml', 
                    variables = {'filesystems':filesystems})

    

class LinodeStaticInfo(object):
    
    @classmethod
    def load(cls):
        cls.plans = lin.get_plans()
        cls.dcs = lin.get_datacenters()
        
        cls.labels_to_ids = {}
        cls.storage_to_ids = {}
        cls.ids = []
        for plan in cls.plans:
            label = plan['LABEL']
            storage = plan['DISK'] # Just an integer in GB
            id = plan['PLANID']
            
            cls.ids.append(id)
            cls.labels_to_ids[label] = id
            cls.storage_to_ids[storage] = id
            
    @classmethod
    def is_valid_id(cls, id):
        assert cls.plans is not None
        assert cls.ids is not None
        return id in cls.ids
        
    @classmethod
    def id_from_label(cls, label):
        assert cls.plans is not None
        assert cls.labels_to_ids is not None
        return cls.labels_to_ids.get(label, None)

    @classmethod
    def id_from_storage(cls, storage):
        assert cls.plans is not None
        assert cls.storage_to_ids is not None
        return cls.storage_to_ids.get(storage, None)
        
    @classmethod
    def dc_id(cls, datacenter):
        assert cls.dcs is not None
        dc_id = lin.get_datacenter(datacenter, cls.dcs)
        return dc_id
        


class DictValidator(object):
    def __init__(self, d):
        self.d = d
        self.errors = []

    def is_valid(self):
        return len(self.errors) == 0
        
    def assert_exists(self, key):
        try:
            dp.get(self.d, key)
        except KeyError as e:
            self.errors.append("Missing key: '%s'" % (key))
            return False
            
        return True

    def assert_int(self, key):
        try:
            value = dp.get(self.d, key)
        except KeyError as e:
            self.errors.append("Missing key: '%s'" % (key))
            return False
        
        if type(value) is not int:
            self.errors.append("Expecting integer value for: '%s'" % (key))
            return False
            
        return True
        
    def assert_value(self, key, expected_val):
        try:
            val = dp.get(self.d, key)
        except KeyError as e:
            self.errors.append("Missing key: '%s'" % (key))
            return False
        
        if val != expected_val:
            self.errors.append("Expected '%s' for '%s', got '%s'" % (expected_val, key, val))
            return False
            
        return True
        
    def add_error(self, errormsg):
        self.errors.append(errormsg)
