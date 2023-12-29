#!/bin/bash


rm /etc/asterisk/sip.conf

# # # Substitute environment variables
sed 's#\$LOCAL_NET#'"$LOCAL_NET"'#g' /etc/asterisk/sip.conf.template > /etc/asterisk/sip.tmp.conf
sed 's#\$EXTERNAL_IP#'"$EXTERNAL_IP"'#g' /etc/asterisk/sip.tmp.conf > /etc/asterisk/sip.conf


# Start Asterisk
exec asterisk -fvvvvvvvv