DISCONTINUATION OF PROJECT

This project will no longer be maintained by Intel.

Intel has ceased development and contributions including, but not limited to, maintenance, bug fixes, new releases, or updates, to this project.  

Intel no longer accepts patches to this project.

If you have an ongoing need to use this project, are interested in independently developing it, or would like to maintain patches for the open source software community, please create your own fork of this project.  

Contact: webadmin@linux.intel.com
﻿# Intel® Optane™ persistent memory Power and Performance User Guide (PnP)

## Instructions for Intel® Optane™ persistent memory Performance Sweep

This script measures PMem idle latency, loaded latency, and maximum bandwidth for various scenarios using MLC to test an App Direct namespace containing a filesystem and mounted as DAX. Use the latest available copy of MLC (https://software.intel.com/en-us/articles/intelr-memory-latency-checker).

It is possible to run the script (pmem_perf_sweep.sh) with no arguments if the namespace is mounted at /mnt/pmem and the MLC binary mlc_avx512 is in the same directory as the script. Otherwise, these paths can be specified as command line options to the pmem_perf_sweep.sh. 

The number of PMem DIMMs is detected first with ndctl and if that fails it attempts to use ipmctl.  
If both utilities are missing the user is asked to input the number of DIMMs belonging to the specified namespace.
The number of CPU cores per socket is also detected. The CPU cores of socket 0 are used by default for load traffic; to modify use optional command syntax -s <socket>. If changing to use a different socket please ensure you point to the pmem mounted on that socket as well.

The script will take approximately 15 minutes to complete. A summary of each metric and the system configuration is printed to Linux* display (stdout). A date-stamped outputs directory is also created containing the various MLC outputs.

## Pre-Conditions

Use a terminal from which the stdout may be captured. The pmem_perf_sweep.sh (mlc) displayed output will need to be cut/paste into the analysis .xlsx spreadsheet after the test completion. Alternatively, use standard Linux command support to redirect the stdout to a text file for collection. 

## Performance Test Steps

* Download and install latest MLC software on the Linux, System Under Test (SUT).

* Copy the PnP script (pmem_perf_sweep.sh) to the Linux, SUT. Add execute permissions.
  * > chmod +x pmem_perf_sweep.sh
  
* Boot into the BIOS setup menu or configure the BIOS Power Throttler Configuration setting as described in the Intel_Optane_PMem_ES2_PnP_Guidance, pg. 39.

* UEFI CLI (create goal) configure the App Direct interleaved persistent memory allocation.
  * UEFI CLI:   
     * > ipmctl.efi create -f -goal
     * > reset      
  * Software Management:
     * > ipmctl create -f -goal
     * > reboot
     
* Create an App Direct namespace on the persistent memory region associated with CPU 0, UEFI CLI example syntax.	  
  * UEFI CLI:   
    * > ipmctl.efi show -region -socket 0
    * > ipmctl.efi create -namespace -region <RegionID>
  * Software Management:   
    * > ipmctl show -region -socket 0
    * > ndctl create-namespace --region <RegionID>

* Boot to Linux OS. Identify the namespace device. Then create and mount a DAX enabled file system. Device /dev/pmem0 is used in this example the same as the default mount point configured in the pmem_perf_sweep.sh script (/mnt/pmem).
  * > ls /dev/pmem*
  * > mkdir -p /mnt/pmem
  * > mkfs.ext4 -b 4096 -E stride=512 -F 
  * Mount with DAX option:
  * > mount -o dax /dev/pmem0 /mnt/pmem

* Execute the performance script, specify the path to the mlc executable if necessary.
  Other Optional arguments are:
  * -p \<Path to mounted PMEM directory\>
    * By default, the pmem memory is expected to be mounted to /mnt/pmem
  * -s \<Socket\> 
    * By default, Socket 0 is used for load the traffic

  The below example also includes syntax to collect stdout to a logfile. 
  Note: The script default path is: MLC=./mlc_avx512
    * ./pmem_perf_sweep.sh -m /root/mlc/Linux/mlc_avx512 -p /mnt/pmem -s 0 | tee -a PMem_PnP_result.log
