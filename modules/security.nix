{
  security = {
    auditd.enable = true;
    audit = {
      enable = true;
      rules = [
        "-a always,exit -F path=/etc/passwd -F perm=wa -F key=identity"
        "-a always,exit -F path=/etc/group -F perm=wa -F key=identity"
        "-a always,exit -F path=/etc/shadow -F perm=wa -F key=identity"
        "-a always,exit -F arch=b64 -S init_module,finit_module,delete_module -F key=modules"
        "-a always,exit -F arch=b64 -S adjtimex,settimeofday,clock_settime -F key=time-change"
        "-a always,exit -F arch=b64 -C euid!=uid -F euid=0 -S execve -F key=privesc"
      ];
    };
  };
}
