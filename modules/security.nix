{
  security = {
    # sudo takes hutao's password, and no agent is ever forwarded to the box.
    # deploy-rs asks for the password once per deploy (interactiveSudo in
    # flake.nix) and pipes it to every sudo, so the automatic rollback still
    # never stops to ask. By hand, `ssh -t` gives sudo a terminal to prompt on;
    # scripts/rcon.sh does the same.
    #
    # A shell as hutao without the password (say, something that wrote hutao's
    # authorized_keys) no longer gets root through sudo.
    sudo.wheelNeedsPassword = true;

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
