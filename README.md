# multipartimage

Simply run script to create the dual-os.img and dual-os.vhd file

```bash
chmod +x make_image.sh
./make_image.sh
```

once completed you can scp the VHD or img file off the machine to try in emulators (Hyper-V [vhd] or QEMU [img])

```bash
#copy img file
scp user@ipaddress:dual-os.img dual-os.img
# copy vhd file
scp user@ipaddress:dual-os.vhd dual-os.vhd
```
