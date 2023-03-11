#!/bin/bash

# Instalando o docker-compose
wget https://github.com/docker/compose/releases/download/1.28.5/docker-compose-Linux-x86_64
sudo mv docker-compose-Linux-x86_64 /usr/local/bin/docker-compose
sudo chmod 755 /usr/local/bin/docker-compose

# Criando os diretórios necessários
mkdir -p registry/data/registry
mkdir -p registry/data/nginx

# Criando o certificado auto-assinado do registry
openssl11 req -x509 -newkey rsa:4096 \
   -keyout registry/data/nginx/tls.key \
   -out registry/data/nginx/tls.crt \
   -days 3650 \
   -subj '/CN='$(hostname -f)'' \
   -addext 'subjectAltName=DNS:'$(hostname -f)',IP:'$(hostname -i)'' \
   -nodes

# Instalando o certicicado localmente
sudo mkdir -p /etc/docker/certs.d/$(hostname -f)
sudo cp registry/data/nginx/tls.crt /etc/docker/certs.d/$(hostname -f)

# Criando o serviceblock do nginx
cat > registry/data/nginx/default.conf <<EOF
server {
    listen 443 ssl default_server;
    client_max_body_size 2000M;

    ssl_certificate /etc/nginx/conf.d/tls.crt;
    ssl_certificate_key /etc/nginx/conf.d/tls.key;

    location / {
      # Do not allow connections from docker 1.5 and earlier
      # docker pre-1.6.0 did not properly set the user agent on ping, catch "Go *" user agents
      if (\$http_user_agent ~ "^(docker\/1\.(3|4|5(?!\.[0-9]-dev))|Go ).*\$" ) {
        return 404;
      }

      proxy_pass                          http://registry:5000;
      proxy_set_header  Host              \$http_host;   # required for docker client's sake
      proxy_set_header  X-Real-IP         \$remote_addr; # pass on real client's IP
      proxy_set_header  X-Forwarded-For   \$proxy_add_x_forwarded_for;
      proxy_set_header  X-Forwarded-Proto \$scheme;
      proxy_read_timeout                  900;
    }
}
EOF

# Criando o docker-compose
cat > registry/docker-compose.yaml <<EOF
version: '3'
services:
  registry:
    restart: always
    image: registry:2
    environment:
      REGISTRY_STORAGE_FILESYSTEM_ROOTDIRECTORY: /data
    volumes:
      - ./data/registry:/data
  nginx-registry:
    restart: always
    image: nginx:1.19-alpine
    ports:
    - "443:443"
    volumes:
      - ./data/nginx:/etc/nginx/conf.d
EOF

# Criando script de listagem
cat > registry/lista-images.sh <<EOF
#!/bin/bash

REGISTRY_HOST="$(hostname -f)"

REPOS=\`curl -sk https://\${REGISTRY_HOST}/v2/_catalog | jq .repositories | grep -v '\[\|\]' | sed 's/"//g' | sed 's/,//g' | sed 's/[[:blank:]]//g'\`

echo
echo "-----------------------------------"
echo "Registry: \${REGISTRY_HOST}"
echo "-----------------------------------"
echo
for i in \`echo \$REPOS\`
	do
		curl -sk https://\${REGISTRY_HOST}/v2/\$i/tags/list | jq
	done
EOF

chmod +x registry/lista-images.sh

# Iniciando o docker-compose
cd registry && docker-compose up -d