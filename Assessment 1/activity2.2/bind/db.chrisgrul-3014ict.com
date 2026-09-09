; Forward zone file
; Replace YOURDOMAIN with your actual domain name throughout this file
;
$TTL    604800
@       IN      SOA     ns1.chrisgrul-3014ict.com. admin.chrisgrul-3014ict.com. (
                              2         ; Serial
                         604800         ; Refresh
                          86400         ; Retry
                        2419200         ; Expire
                         604800 )       ; Negative Cache TTL
;
@       IN      NS      ns1.chrisgrul-3014ict.com.

ns1     IN      A       192.168.1.1
ns1	IN	AAAA	2404:9400:29c1:df10::1
@       IN      A       192.168.1.80
@	IN	AAAA	2404:9400:29c1:df10::80
www     IN      CNAME	chrisgrul-3014ict.com.
mail    IN      A       192.168.1.80
mail	IN	AAAA	2404:9400:29c1:df10::80

