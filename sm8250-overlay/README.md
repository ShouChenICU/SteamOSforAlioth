Files that only go into the 865 (SM8250) image: audio (UCM, WirePlumber),
InputPlumber profiles, udev rules and the steamos-manager device list for the
Retroid Pocket 5 / Flip 2 / Mini / Mini V2, AYN Thor Lite, MANGMI Air Y Pro
/ Pocket Max and AYANEO Pocket MICRO 2. apply-overlays.sh copies them only when SOC=sm8250 and removes
them from a reused rootfs otherwise.

The power key (PMIC `pmic_pwrkey`) is handled in Game Mode by
steamos-powerbuttond, started by etc/systemd/user/gamescope-session.target.d/
99-sm8250-powerbuttond.conf (the Frame's own unit needs SteamVR). Both Retroid
Pocket 5 and Flip 2 use the UCM files under usr/share/alsa/ucm2/Retroid/;
codecs/wsa881x/init.conf is ours because alsa-ucm-conf has none.
