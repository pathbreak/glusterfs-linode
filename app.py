from cluster_plan import LinodeStaticInfo

def app_init(): 
    LinodeStaticInfo.load()
    
if __name__ == '__main__':
    app_init()
