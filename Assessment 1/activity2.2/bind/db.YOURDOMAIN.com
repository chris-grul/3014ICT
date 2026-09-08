; Forward zone file
; Replace YOURDOMAIN with your actual domain name throughout this file
;
$TTL    604800
@       IN      SOA     ns1.YOURDOMAIN.com. admin.YOURDOMAIN.com. (
                              2         ; Serial
                         604800         ; Refresh
                          86400         ; Retry
                        2419200         ; Expire
                         604800 )       ; Negative Cache TTL
;
@       IN      NS      ns1.YOURDOMAIN.com.

ns1     IN      A       192.168.1.1
@       IN      A       192.168.1.80
www     IN      A       192.168.1.80
mail    IN      A       192.168.1.80
