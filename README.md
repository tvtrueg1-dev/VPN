# OpenVPN Setup

สคริปต์ติดตั้ง OpenVPN server บน VPS (Ubuntu/Debian/CentOS/RHEL) พร้อมออก client profile แบบ `.ovpn` ที่ฝัง certificate ไว้ในไฟล์เดียว

## Quick start (one-liner)

```bash
curl -fsSL https://raw.githubusercontent.com/tvtrueg1-dev/VPN/main/openvpn-one.sh | sudo bash -s -- myphone
```

คำสั่งเดียวจะติดตั้ง OpenVPN, สร้าง CA/server cert, เปิด IP forwarding + NAT, ตั้ง firewall และสร้างไฟล์ client ที่ `/root/myphone.ovpn`

## ปรับค่า

```bash
curl -fsSL https://raw.githubusercontent.com/tvtrueg1-dev/VPN/main/openvpn-one.sh \
  | sudo VPN_PORT=443 VPN_PROTO=tcp DNS1=1.1.1.1 bash -s -- myphone
```

ตัวแปรที่ใช้ได้: `VPN_PORT`, `VPN_PROTO`, `VPN_SUBNET`, `VPN_NETMASK`, `VPN_CIDR`, `DNS1`, `DNS2`, `SERVER_NAME`

## แยกสคริปต์

```bash
sudo ./install-openvpn-server.sh          # ติดตั้ง server
sudo ./make-client.sh laptop 203.0.113.10 # ออก client
sudo ./revoke-client.sh laptop            # เพิกถอน client
```

## หลังติดตั้ง

- นำเข้า `/root/<client>.ovpn` ในแอป OpenVPN Connect
- ตรวจสถานะ: `systemctl status openvpn-server@server`
- ดู log: `journalctl -u openvpn-server@server -f`
- อย่าลืมเปิดพอร์ต VPN ใน firewall/cloud security group ของ VPS

## Security

- ใช้ `tls-crypt` + AES-256-GCM และ CRL สำหรับเพิกถอน client
- ไฟล์ `.ovpn` มี private key อยู่ภายใน เก็บเป็นความลับและไม่ควร commit ขึ้น repository
