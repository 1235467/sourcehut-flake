# SourceHut build worker guest image with Nix.
#
# Built entirely as a Nix derivation (no Containerfile / podman build),
# so its store closure — including the gVisor-compatible patched Lix —
# substitutes from binary caches instead of compiling on the deploy
# host. builds.sr.ht-images.service loads the result with podman load.
{ pkgs }:

let
  # Lix patched to tolerate gVisor's incomplete namespace/capability
  # emulation: ambient-caps and capset clearing return EINVAL under
  # runsc, the strict parent-PID check misfires, and SO_PEERGROUPS is
  # unsupported. All three are hardening measures, not correctness, so
  # ignoring the specific errno is safe inside the runsc sandbox.
  lix = pkgs.lix.overrideAttrs (old: {
    patches = (old.patches or [ ]) ++ [ ./lix-gvisor.patch ];
  });

  nixbldUsers = pkgs.runCommand "nixbld-users" { } ''
    mkdir -p $out
    {
      printf 'nixbld:x:30000:nixbld1'
      for i in $(seq 2 32); do printf ",nixbld$i"; done
      echo
    } > $out/group
    for i in $(seq 1 32); do
      echo "nixbld$i:x:$((30000 + i)):30000::/var/empty:/bin/false"
    done > $out/passwd
  '';

  entrypoint = pkgs.writeShellScript "entrypoint" ''
    echo "starting nix-daemon"
    ${lix}/bin/nix-daemon --daemon &
    echo "starting sshd"
    exec ${pkgs.openssh}/bin/sshd -D -e -f /etc/sshd_config
  '';

  etc = {
    passwd = ''
      root:x:0:0::/root:/bin/bash
      nobody:x:65534:65534::/var/empty:/bin/false
      sshd:x:74:74::/var/empty:/bin/false
      build:x:1000:1000::/home/build:/bin/bash
    '';
    shadow = ''
      root::0::::::
      nobody::0::::::
      sshd::0::::::
      build::0::::::
    '';
    group = ''
      root:x:0:
      nogroup:x:65534:
      sshd:x:74:
      build:x:1000:
    '';
    nsswitch = ''
      passwd: files
      group: files
      shadow: files
      hosts: files dns
    '';
    sudoers = ''
      root ALL=(ALL) ALL
      build ALL=(ALL) NOPASSWD:ALL
    '';
    sshd_config = ''
      Port 22
      AddressFamily any
      ListenAddress 0.0.0.0
      HostKey /etc/ssh/ssh_host_rsa_key
      HostKey /etc/ssh/ssh_host_ecdsa_key
      HostKey /etc/ssh/ssh_host_ed25519_key
      PermitRootLogin prohibit-password
      PasswordAuthentication yes
      PermitEmptyPasswords yes
      ChallengeResponseAuthentication no
      UsePAM yes
      PrintMotd no
      AcceptEnv LANG LC_*
      Subsystem sftp ${pkgs.openssh}/libexec/sftp-server
    '';
    nixConf = ''
      experimental-features = nix-command flakes
      # gVisor does not implement namespace creation, so the nix
      # sandbox (mount/userns per builder) cannot run inside this
      # guest. runsc is the isolation boundary; builders still run as
      # unprivileged nixbld users.
      sandbox = false
      build-users-group = nixbld
      trusted-users = root build
    '';
    profile = ''
      export PATH=/nix/var/nix/profiles/default/bin:/usr/bin:/bin:/usr/sbin:/sbin
      export SSL_CERT_FILE=/etc/ssl/certs/ca-bundle.crt
      export GIT_SSL_CAINFO=/etc/ssl/certs/ca-bundle.crt
      export NIX_SSL_CERT_FILE=/etc/ssl/certs/ca-bundle.crt
      export CURL_CA_BUNDLE=/etc/ssl/certs/ca-bundle.crt
      export NIX_PATH=nixpkgs=flake:nixpkgs
    '';
    hosts = ''
      127.0.0.1 localhost
      ::1 localhost
    '';
    resolv = "nameserver 1.1.1.1\nnameserver 8.8.8.8\n";
    pamSshd = ''
      auth sufficient pam_permit.so
      account sufficient pam_permit.so
      password sufficient pam_permit.so
      session sufficient pam_permit.so
    '';
    pamSudo = ''
      auth sufficient pam_permit.so
      account sufficient pam_permit.so
      session sufficient pam_permit.so
    '';
  };
in
pkgs.dockerTools.buildLayeredImage {
  name = "buildsrht-nix";
  tag = "latest";

  # Run fakeRootCommands inside a proot-chrooted view of the layer so
  # absolute paths (e.g. /etc) land in the image rather than the build
  # sandbox's own root filesystem.
  enableFakechroot = true;

  contents = [
    pkgs.bashInteractive
    pkgs.gitMinimal
    pkgs.mercurial
    pkgs.curl
    pkgs.cacert
    pkgs.openssh
    lix
    pkgs.busybox
  ];

  # Contents merge into per-file symlinks; /etc, /home and friends are
  # rebuilt here as real directories so ownership, modes and
  # generated host keys land in the layer itself.
  fakeRootCommands = ''
    chmod -R u+w /etc /home /var /run /root /usr 2>/dev/null || true
    rm -rf /etc /home /var /run /root /usr
    mkdir -p /etc/pam.d /etc/nix /etc/ssh /etc/ssl/certs \
      /home/build/.ssh /home/build/secrets \
      /tmp /var/tmp /var/empty /run/sshd /root \
      /nix/var/nix/daemon-socket /usr/bin /usr/sbin

    cat ${pkgs.writeText "passwd" etc.passwd} > /etc/passwd
    cat ${pkgs.writeText "group" etc.group} > /etc/group
    cat ${pkgs.writeText "nsswitch.conf" etc.nsswitch} > /etc/nsswitch.conf
    cat ${pkgs.writeText "shadow" etc.shadow} > /etc/shadow
    cat ${pkgs.writeText "sudoers" etc.sudoers} > /etc/sudoers
    cat ${pkgs.writeText "sshd_config" etc.sshd_config} > /etc/sshd_config
    cat ${pkgs.writeText "nix.conf" etc.nixConf} > /etc/nix/nix.conf
    cat ${pkgs.writeText "profile" etc.profile} > /etc/profile
    cat ${pkgs.writeText "hosts" etc.hosts} > /etc/hosts
    cat ${pkgs.writeText "resolv.conf" etc.resolv} > /etc/resolv.conf
    cat ${pkgs.writeText "pam-sshd" etc.pamSshd} > /etc/pam.d/sshd
    cat ${pkgs.writeText "pam-sudo" etc.pamSudo} > /etc/pam.d/sudo
    cat ${nixbldUsers}/passwd >> /etc/passwd
    cat ${nixbldUsers}/group >> /etc/group

    ln -sf ${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt /etc/ssl/certs/ca-bundle.crt
    ln -sf ${pkgs.busybox}/bin/busybox /usr/bin/env
    ln -sf ${pkgs.bashInteractive}/bin/bash /bin/sh
    cp ${entrypoint} /entrypoint

    chmod 755 /entrypoint /etc
    chmod 600 /etc/shadow
    chmod 440 /etc/sudoers
    chmod 1777 /tmp /var/tmp /nix/var/nix/daemon-socket
    chmod 700 /root /home/build/.ssh
    chown -R 0:0 /etc /tmp /var /run /root /usr /entrypoint /nix/var
    chown -R 1000:1000 /home/build

    ${pkgs.openssh}/bin/ssh-keygen -A

    # sudo must be a real file to carry the setuid bit (store paths
    # can't be setuid); build is a trusted nix user so this stays a
    # convenience path rather than a required one.
    cp ${pkgs.sudo}/bin/sudo /usr/bin/sudo
    chmod 4755 /usr/bin/sudo
  '';

  config = {
    Cmd = [ "/entrypoint" ];
    ExposedPorts = { "22/tcp" = { }; };
    Env = [
      "PATH=/nix/var/nix/profiles/default/bin:/usr/bin:/bin:/usr/sbin:/sbin"
      "SSL_CERT_FILE=/etc/ssl/certs/ca-bundle.crt"
      "NIX_SSL_CERT_FILE=/etc/ssl/certs/ca-bundle.crt"
      "GIT_SSL_CAINFO=/etc/ssl/certs/ca-bundle.crt"
      "CURL_CA_BUNDLE=/etc/ssl/certs/ca-bundle.crt"
      "NIX_PATH=nixpkgs=flake:nixpkgs"
    ];
  };
}
