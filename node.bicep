// az deployment group create  --template-file node.bicep --parameters node.parameters.local.json --resource-group OpenFOAMDemo --name 0000025
// https://docs.microsoft.com/en-us/azure/templates/microsoft.compute/virtualmachines?tabs=bicep

@description('How many nodes to deploy')
param count int

@description('The prefix for the names of the nodes being created')
param name string = 'node'

@description('The region for the nodes')
param location string = 'eastus'

@description('The customer ID for tagging the nodes (for billing, etc.)')
param customerId string

@description('The VM size for the nodes')
param vmSize string = 'Standard_HB120rs_v3'

@description('The physical storage type for the node OS disks')
@allowed([
  'Standard_LRS'
  'Premium_LRS'
  'StandardSSD_LRS'
  'Premium_ZRS'
  'StandardSSD_ZRS'
])
param osDiskType string = 'Premium_LRS'

@description('The SSH login username')
param adminUsername string = 'demoadmin'

@description('The SSH login password')
@secure()
param adminPassword string

@description('The name of the storage account for shared info')
param storageAccount string

@description('The storage account token for writing to the storage account')
param storageAccountToken string

// end of parameters
// ----------------------------------------------------------------------------------------
// variables

var topNode = format('{0:D2}', count-1)
var controllerNode = concat(name, '00')
var storageContainerName = concat(customerId, '-', name)
var networkName = concat(name, '-vnet')
var subnetName = 'nodes'

// ----------------------------------------------------------------------------------------
// storage configuration
resource storage 'Microsoft.Storage/storageAccounts@2021-02-01' existing = {
  name: storageAccount
}

resource storageContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2021-02-01' = {
  name: '${storageAccount}/default/${storageContainerName}'
}

// ----------------------------------------------------------------------------------------
// network configuration

resource network 'Microsoft.Network/virtualNetworks@2020-11-01' = {
  name: networkName
  location: location
  tags: {
    customerId: customerId
  }
  properties: {
    addressSpace: {
      addressPrefixes: [
        '192.168.0.0/16'
      ]
    }
  }
}

resource subnet 'Microsoft.Network/virtualNetworks/subnets@2020-11-01' = {
  name: subnetName
  parent: network
  properties: {
    addressPrefix: '192.168.0.0/24'
  }
}

// ----------------------------------------------------------------------------------------
// shared node configuration

// https://docs.microsoft.com/en-us/azure/virtual-machines/extensions/hpc-compute-infiniband-linux
// https://docs.microsoft.com/en-us/azure/virtual-machines/workloads/hpc/enable-infiniband
resource infinibandInstaller 'Microsoft.Compute/virtualMachines/extensions@2020-12-01' = [for i in range(0,count): {
  name: concat(name, format('{0:D2}', i), '/inifiniband')
  location: location
  dependsOn: [
    node
  ]
  tags: {
    customerId: customerId
  }
  properties: {
    publisher: 'Microsoft.HpcCompute'
    type: 'InfiniBandDriverLinux'
    typeHandlerVersion: '1.1'
    autoUpgradeMinorVersion: true
  }
}]

// ----------------------------------------------------------------------------------------
// controller node
resource controller 'Microsoft.Compute/virtualMachines@2020-12-01' = {
  name: controllerNode
  location: location
  dependsOn: [
    storageContainer
  ]
  tags: {
    customerId: customerId
  }
  properties: {
    hardwareProfile: {
      vmSize: vmSize
    }
    storageProfile: {
      imageReference: {
        publisher: 'canonical'
        offer: '0001-com-ubuntu-server-focal'
        sku: '20_04-lts-gen2'
        version: 'latest'
      }
      osDisk: {
        osType: 'Linux'
        name: concat(controllerNode, '-osDisk')
        createOption: 'FromImage'
        managedDisk: {
          storageAccountType: osDiskType
        }
      }
    }
    osProfile: {
      computerName: controllerNode
      adminUsername: adminUsername
      adminPassword: adminPassword
      linuxConfiguration: {
        disablePasswordAuthentication: false
        provisionVMAgent: true
      }
      allowExtensionOperations: true
      customData: base64('''
#cloud-config

# this is dumb and should not be needed, not sure what is going on
bootcmd:
  - curl -L "https://dl.openfoam.com/pubkey.gpg" 2>/dev/null | gpg --dearmor > "/etc/apt/trusted.gpg.d/openfoam.gpg"
  - wget -O - https://aka.ms/downloadazcopy-v10-linux | gunzip - | tar xfo - --wildcards --no-anchored --strip-components 1 --directory /usr/sbin azcopy
  - chmod 755 /usr/sbin/azcopy

timezone: "America/New_York"

apt:
  preserve_sources_list: true
  sources:
    openfoam:
      source: 'deb [trusted=yes] https://dl.openfoam.com/repos/deb $RELEASE main'
      key: |
        -----BEGIN PGP PUBLIC KEY BLOCK-----
        Version: GnuPG v1
        
        mQENBFeGXxcBCACpBHAlBk67MVnHtLux0eI/gJuo5eTSLzQd4TYXgLbOXs8aCEH1
        7JKAS24m2KwtcqBwTfW+wb54b0HHzJn81Zpmd7JXt/6oX4wZHTXMED9/P893UHOI
        sC5e1O9BzDQ4J1Ot4SMMRElNZyxdcbqGTvp+t67xrBqG1ZoXO4WYfUemNT+I4xrs
        xzguKVvL+yWB8hHZ6JpzScC3xQM9JSL7Gzmv6NvXkr+fDw6Ct/aUdB3PjbSlINKC
        4sTfQRvokE6nf7SVMqiPTDup+E1DLLfzvUJSxoCGc34wbiuA5ThqE11Y4DiLZaLe
        r3V03nbEJY2T1cGExS7njMs3uFiICovfWdmXABEBAAG0KE9wZW5GT0FNIEZvdW5k
        YXRpb24gPGFkbWluQG9wZW5mb2FtLm9yZz6JATcEEwEKACEFAleGXxcCGwMFCwkI
        BwMFFQoJCAsFFgMCAQACHgECF4AACgkQbA2scosp2BdYdAf+K1+RfWZZSZBwqpPR
        MNvV8RkpQ5k7m68NdFRha6cmxCnFJwyw7EJrI0ZXrnz+VstmTvTt05a2ml3MvMdK
        WBZs0/dA3LuqYLjGCPCDB5iu5w/sVCXyawZejoe/X3/ODRDgUiJ1LCKQbhwHqNda
        yIH7gBYdmy3bzjncm5lYn/Jxw42qAOog/Lnwrru5EIeTyNWrk495KEjTasb9L31I
        61G5oEkZsoDk6kPIf93lHBzey60wyc3dU6jQAbnjCB1PvcQP12uv8MK0bO6E5TKS
        BYj/W3wayzaU/FD7NIbCbsHqc1rDNDutp3Y6B5z3tP3bSJ70FfoWfGWuuPG6uEJy
        W5EHUbkBDQRXhl8XAQgAxQnYD9yvl19ULD3el+vhwUb+xIj2gkpyCfP3g6as68OR
        6QsHfYyFrLxBCroGb/fx4AT240ikErplgYThr+fwVl8CXyWtdrgrUwU8DopTTiTN
        xYxbxklljp8ZO8rJNPpIWJBTIUSZv+2sd+LrkcEocZ0tWsUoshlc3iBYtmiO+HbW
        9yAxKHOkA3eooSZHERs8BIQ+ZLhv3x5FB73jbMYOIB0dqU2GrbDvFBnKx9AWheCd
        JsOAlAlGnNcyI4ZDdJ33DozCUgalxmTMGrfPyCvz9zqKm1gQsscmrNFij/F9TeNY
        +oEjRoXwwnyM5YiexMcxhLp2NPjagFU0lNS8gCFy2QARAQABiQEfBBgBCgAJBQJX
        hl8XAhsMAAoJEGwNrHKLKdgXShUH/1rUNk9MvoZ9HBdvm7/z70J64cnNPjIwPuhO
        5FMihCMmnsESjCgzrP6rVDOma4psf7fwEe8m1cltl8gVQ1cZIo2LO/0XnbBeo9b9
        hA+RqtKz9IZYqNzbvGxEbkhMf6O/TDSFmJpAueh8D3/Dgcrvya0bflkwoGl7RDKu
        Iq68v4Ri1s4LAq8RCIsB85NKds2vLIAuMrhbhtwYEVgalPotMMHX/MMrKL5T95Ac
        /GuySu+Yk7kmfrFq0SIzP1BFGv+l84ke18zMu0ssGHVGY0eaEEpO2aude+HhMJqD
        +PmSM0ZDHsJu4It2PIIGtgGWfai9ddXOI2+z8W6ugsKr/tq7Sik=
        =DlyX
        -----END PGP PUBLIC KEY BLOCK-----

packages:
  - make
  - g++
  - net-tools
  - ibutils
  - infiniband-diags
  - ibverbs-utils
  - openfoam2012-default
  - slurmd
  - slurm-client
  - slurmctld

write_files:
  - path: /etc/slurm-llnl/slurm.conf
    permissions: '0644'
    content: |     
      MpiDefault=none
      ProctrackType=proctrack/linuxproc
      ReturnToService=1
      SlurmctldPidFile=/run/slurmctld.pid
      SlurmctldPort=6817
      SlurmdPidFile=/run/slurmd.pid
      SlurmdPort=6818
      SlurmdLogFile=/var/log/slurm-llnl/slurm.log
      SlurmdSpoolDir=/var/spool/slurm
      SlurmUser=slurm
      StateSaveLocation=/var/spool/slurm
      SwitchType=switch/none
      TaskPlugin=task/affinity
      InactiveLimit=0
      KillWait=30
      MinJobAge=300
      SlurmctldTimeout=120
      SlurmdTimeout=300
      Waittime=0
      SchedulerType=sched/backfill
      SelectType=select/cons_tres
      SelectTypeParameters=CR_Core
      AccountingStorageType=accounting_storage/none
      AccountingStoreJobComment=YES
      ClusterName=cluster
      JobCompType=jobcomp/none
      JobAcctGatherFrequency=30
      JobAcctGatherType=jobacct_gather/none
      SlurmctldDebug=info
      SlurmdDebug=info

runcmd:
- systemctl disable --now slurmctld
- systemctl disable --now slurmd
- chown slurm:slurm /var/spool/slurm
- chown slurm:slurm /etc/slurm-llnl/slurm.conf
''')
    }
    networkProfile: {
      networkInterfaces: [
        {
          id: controllerNic.id
        }
      ]
    }
    diagnosticsProfile: {
      bootDiagnostics: {
        enabled: true
      }
    }
  }
}

// https://ochzhen.com/blog/azure-custom-script-extension-linux
resource controllerConfiguration 'Microsoft.Compute/virtualMachines/extensions@2020-12-01' = {
  name: concat(controllerNode, '/CustomScriptExtension')
  location: location
  dependsOn: [
    controller
  ]
  tags: {
    customerId: customerId
  }
  properties: {
    publisher: 'Microsoft.Azure.Extensions'
    type: 'CustomScript'
    typeHandlerVersion: '2.1'
    autoUpgradeMinorVersion: true
    settings: {
      'commandToExecute': 'echo SlurmctldHost=${controllerNode} >> /etc/slurm-llnl/slurm.conf && echo NodeName=${name}[00-${topNode}] CPUs=`nproc` >> /etc/slurm-llnl/slurm.conf && echo PartitionName=debug Nodes=${name}[00-${topNode}] Default=YES MaxTime=INFINITE State=UP >> /etc/slurm-llnl/slurm.conf && mkdir /etc/munge && dd if=/dev/urandom bs=1 count=1024 > /etc/munge/munge.key && chmod 444 /etc/munge/munge.key && chmod 555 /etc/munge && /usr/sbin/azcopy copy /etc/munge/munge.key "https://${storageAccount}.blob.core.windows.net/${storageContainerName}/munge.key${storageAccountToken}"'
    }
  }
}

resource controllerNsg 'Microsoft.Network/networkSecurityGroups@2020-11-01' = {
  name: concat(controllerNode, '-nsg')
  location: location
  tags: {
    customerId: customerId
  }
  properties: {
    securityRules: [
      {
        name: 'SSH-incoming'
        properties: {
          protocol: 'Tcp'
          sourcePortRange: '*'
          destinationPortRange: '22'
          sourceAddressPrefix: '*'
          destinationAddressPrefix: '*'
          access: 'Allow'
          priority: 100
          direction: 'Inbound'
          sourcePortRanges: []
          destinationPortRanges: []
          sourceAddressPrefixes: []
          destinationAddressPrefixes: []
        }
      }
    ]
  }
}

resource controllerPip 'Microsoft.Network/publicIPAddresses@2020-11-01' = {
  name: concat(controllerNode, '-pip')
  location: location
  tags: {
    customerId: customerId
  }
}

resource controllerNic 'Microsoft.Network/networkInterfaces@2020-11-01' = {
  name: concat(controllerNode, '-nic')
  location: location
  tags: {
    customerId: customerId
  }
  properties: {
    ipConfigurations: [
      {
        name: 'ipconfig'
        properties: {
          subnet: {
            id: subnet.id
          }
          publicIPAddress: {
            id: controllerPip.id
          }
        }
      }
    ]
    networkSecurityGroup: {
      id: controllerNsg.id
    }
  }
}

// ----------------------------------------------------------------------------------------
// compute nodes

resource node 'Microsoft.Compute/virtualMachines@2020-12-01' = [for i in range(1,count-1): {
  dependsOn: [
    controller
  ]
  name: concat(name, format('{0:D2}', i))
  location: location
  tags: {
    customerId: customerId
  }
  properties: {
    hardwareProfile: {
      vmSize: vmSize
    }
    storageProfile: {
      imageReference: {
        publisher: 'canonical'
        offer: '0001-com-ubuntu-server-focal'
        sku: '20_04-lts-gen2'
        version: 'latest'
      }
      osDisk: {
        osType: 'Linux'
        name: concat(name, format('{0:D2}', i), '-osDisk')
        createOption: 'FromImage'
        managedDisk: {
          storageAccountType: osDiskType
        }
      }
    }
    osProfile: {
      computerName: concat(name, format('{0:D2}', i))
      adminUsername: adminUsername
      adminPassword: adminPassword
      linuxConfiguration: {
        disablePasswordAuthentication: false
        provisionVMAgent: true
      }
      allowExtensionOperations: true
      customData: base64('''
#cloud-config

# this is dumb and should not be needed, not sure what is going on
bootcmd:
  - curl -L "https://dl.openfoam.com/pubkey.gpg" 2>/dev/null | gpg --dearmor > "/etc/apt/trusted.gpg.d/openfoam.gpg"
  - wget -O - https://aka.ms/downloadazcopy-v10-linux | gunzip - | tar xfo - --wildcards --no-anchored --strip-components 1 --directory /usr/sbin azcopy
  - chmod 755 /usr/sbin/azcopy
  
timezone: "America/New_York"

apt:
  preserve_sources_list: true
  sources:
    openfoam:
      source: 'deb [trusted=yes] https://dl.openfoam.com/repos/deb $RELEASE main'
      key: |
        -----BEGIN PGP PUBLIC KEY BLOCK-----
        Version: GnuPG v1
        
        mQENBFeGXxcBCACpBHAlBk67MVnHtLux0eI/gJuo5eTSLzQd4TYXgLbOXs8aCEH1
        7JKAS24m2KwtcqBwTfW+wb54b0HHzJn81Zpmd7JXt/6oX4wZHTXMED9/P893UHOI
        sC5e1O9BzDQ4J1Ot4SMMRElNZyxdcbqGTvp+t67xrBqG1ZoXO4WYfUemNT+I4xrs
        xzguKVvL+yWB8hHZ6JpzScC3xQM9JSL7Gzmv6NvXkr+fDw6Ct/aUdB3PjbSlINKC
        4sTfQRvokE6nf7SVMqiPTDup+E1DLLfzvUJSxoCGc34wbiuA5ThqE11Y4DiLZaLe
        r3V03nbEJY2T1cGExS7njMs3uFiICovfWdmXABEBAAG0KE9wZW5GT0FNIEZvdW5k
        YXRpb24gPGFkbWluQG9wZW5mb2FtLm9yZz6JATcEEwEKACEFAleGXxcCGwMFCwkI
        BwMFFQoJCAsFFgMCAQACHgECF4AACgkQbA2scosp2BdYdAf+K1+RfWZZSZBwqpPR
        MNvV8RkpQ5k7m68NdFRha6cmxCnFJwyw7EJrI0ZXrnz+VstmTvTt05a2ml3MvMdK
        WBZs0/dA3LuqYLjGCPCDB5iu5w/sVCXyawZejoe/X3/ODRDgUiJ1LCKQbhwHqNda
        yIH7gBYdmy3bzjncm5lYn/Jxw42qAOog/Lnwrru5EIeTyNWrk495KEjTasb9L31I
        61G5oEkZsoDk6kPIf93lHBzey60wyc3dU6jQAbnjCB1PvcQP12uv8MK0bO6E5TKS
        BYj/W3wayzaU/FD7NIbCbsHqc1rDNDutp3Y6B5z3tP3bSJ70FfoWfGWuuPG6uEJy
        W5EHUbkBDQRXhl8XAQgAxQnYD9yvl19ULD3el+vhwUb+xIj2gkpyCfP3g6as68OR
        6QsHfYyFrLxBCroGb/fx4AT240ikErplgYThr+fwVl8CXyWtdrgrUwU8DopTTiTN
        xYxbxklljp8ZO8rJNPpIWJBTIUSZv+2sd+LrkcEocZ0tWsUoshlc3iBYtmiO+HbW
        9yAxKHOkA3eooSZHERs8BIQ+ZLhv3x5FB73jbMYOIB0dqU2GrbDvFBnKx9AWheCd
        JsOAlAlGnNcyI4ZDdJ33DozCUgalxmTMGrfPyCvz9zqKm1gQsscmrNFij/F9TeNY
        +oEjRoXwwnyM5YiexMcxhLp2NPjagFU0lNS8gCFy2QARAQABiQEfBBgBCgAJBQJX
        hl8XAhsMAAoJEGwNrHKLKdgXShUH/1rUNk9MvoZ9HBdvm7/z70J64cnNPjIwPuhO
        5FMihCMmnsESjCgzrP6rVDOma4psf7fwEe8m1cltl8gVQ1cZIo2LO/0XnbBeo9b9
        hA+RqtKz9IZYqNzbvGxEbkhMf6O/TDSFmJpAueh8D3/Dgcrvya0bflkwoGl7RDKu
        Iq68v4Ri1s4LAq8RCIsB85NKds2vLIAuMrhbhtwYEVgalPotMMHX/MMrKL5T95Ac
        /GuySu+Yk7kmfrFq0SIzP1BFGv+l84ke18zMu0ssGHVGY0eaEEpO2aude+HhMJqD
        +PmSM0ZDHsJu4It2PIIGtgGWfai9ddXOI2+z8W6ugsKr/tq7Sik=
        =DlyX
        -----END PGP PUBLIC KEY BLOCK-----

packages:
  - make
  - g++
  - net-tools
  - ibutils
  - infiniband-diags
  - ibverbs-utils
  - openfoam2012-default
  - slurmd
  - slurm-client

write_files:
  - path: /etc/slurm-llnl/slurm.conf
    permissions: '0644'
    content: |     
      MpiDefault=none
      ProctrackType=proctrack/linuxproc
      ReturnToService=1
      SlurmctldPidFile=/run/slurmctld.pid
      SlurmctldPort=6817
      SlurmdPidFile=/run/slurmd.pid
      SlurmdPort=6818
      SlurmdLogFile=/var/log/slurm-llnl/slurm.log
      SlurmdSpoolDir=/var/spool/slurm
      SlurmUser=slurm
      StateSaveLocation=/var/spool/slurm
      SwitchType=switch/none
      TaskPlugin=task/affinity
      InactiveLimit=0
      KillWait=30
      MinJobAge=300
      SlurmctldTimeout=120
      SlurmdTimeout=300
      Waittime=0
      SchedulerType=sched/backfill
      SelectType=select/cons_tres
      SelectTypeParameters=CR_Core
      AccountingStorageType=accounting_storage/none
      #AccountingStorageUser=
      AccountingStoreJobComment=YES
      ClusterName=cluster
      JobCompType=jobcomp/none
      JobAcctGatherFrequency=30
      JobAcctGatherType=jobacct_gather/none
      SlurmctldDebug=info
      SlurmdDebug=info

runcmd:
- systemctl disable --now slurmd
- chown slurm:slurm /var/spool/slurm
- chown slurm:slurm /etc/slurm-llnl/slurm.conf
''')
    }
    networkProfile: {
      networkInterfaces: [
        {
          id: nic[i-1].id
        }
      ]
    }
    diagnosticsProfile: {
      bootDiagnostics: {
        enabled: true
      }
    }
  }
}]

resource nodeConfiguration 'Microsoft.Compute/virtualMachines/extensions@2020-12-01' = [for i in range(1,count-1): {
  name: concat(name, format('{0:D2}', i), '/CustomScriptExtension')
  location: location
  dependsOn: [
    node
  ]
  tags: {
    customerId: customerId
  }
  properties: {
    publisher: 'Microsoft.Azure.Extensions'
    type: 'CustomScript'
    typeHandlerVersion: '2.1'
    autoUpgradeMinorVersion: true
    settings: {
      'commandToExecute': 'echo SlurmctldHost=${controllerNode} >> /etc/slurm-llnl/slurm.conf && echo NodeName=${name}[00-${topNode}] CPUs=`nproc` >> /etc/slurm-llnl/slurm.conf && echo PartitionName=debug Nodes=${name}[00-${topNode}] Default=YES MaxTime=INFINITE State=UP >> /etc/slurm-llnl/slurm.conf && mkdir /etc/munge && /usr/sbin/azcopy copy "https://${storageAccount}.blob.core.windows.net/${storageContainerName}/munge.key${storageAccountToken}" /tmp/munge.key && cp /tmp/munge.key /etc/munge'
    }
  }
}]

resource nic 'Microsoft.Network/networkInterfaces@2020-11-01' = [for i in range(1,count-1): {
  name: concat(name, format('{0:D2}', i), '-nic')
  location: location
  tags: {
    customerId: customerId
  }
  properties: {
    ipConfigurations: [
      {
        name: 'ipconfig'
        properties: {
          subnet: {
            id: subnet.id
          }
        }
      }
    ]
  }
}]


