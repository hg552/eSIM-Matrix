REPLACE="
"

# Set permissions
set_perm_recursive $MODPATH 0 0 0755 0644
set_perm_recursive $MODPATH/system/priv-app/io.github.hg552.esimmatrix.privileged 0 0 0755 0644
chcon -R u:object_r:system_file:s0 $MODPATH/system/priv-app/io.github.hg552.esimmatrix.privileged
set_perm $MODPATH/system/etc/permissions/privapp-permissions-io.github.hg552.esimmatrix.xml 0 0 0644
