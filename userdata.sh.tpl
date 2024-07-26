#!/bin/bash
              yum update -y
              yum install -y amazon-efs-utils
              yum install -y python3-pip
              pip3 install botocore
              file_system_id=${aws_efs_file_system.efs.id}
              efs_mount_point=/mnt/efs
              mkdir -p ${efs_mount_point}
              test -f "/sbin/mount.efs" && echo "${file_system_id}:/ ${efs_mount_point} efs defaults,_netdev" >> /etc/fstab || echo "${file_system_id}.efs.${data.aws_region.current.name}.amazonaws.com:/ ${efs_mount_point} nfs4 defaults,_netdev" >> /etc/fstab
              mount -a