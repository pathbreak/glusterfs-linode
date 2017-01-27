
class MenuItem(object):
    def __init__(self, label, action):
        self.label = label
        self.action = action
        
def display_menu(items):
    for i, item in enumerate(items):
        print('%d. %s' % (i+1, item.label))
    
    choice = raw_input('\nEnter a choice:')
    
    choice = int(choice)
    if choice >= 1 and choice <= len(items):
        items[choice-1].action()
    
def create_cluster():
    print('Creating cluster')

def list_clusters():
    print('List clusters')
    
def manage_cluster():
    print('Manage a cluster')
        
if __name__ == '__main__':
    main_menu = [
        MenuItem('Create a cluster', create_cluster),
        MenuItem('List clusters', list_clusters),
        MenuItem('Manage a cluster', manage_cluster)
    ]
    display_menu(main_menu)
