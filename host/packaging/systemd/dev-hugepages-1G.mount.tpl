[Unit]
Description=HugeTLB 1G pages filesystem (Tenstorrent)
Documentation=man:systemd.mount(5) man:hugetlbfs(7)
DefaultDependencies=no
Before=sysinit.target
ConditionPathExists=/dev

[Mount]
What=hugetlbfs
Where=/dev/hugepages-1G
Type=hugetlbfs
Options=mode=777,pagesize=1024M

[Install]
WantedBy=sysinit.target
