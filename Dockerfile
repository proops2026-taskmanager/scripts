FROM node:20-alpine
WORKDIR /app
COPY package*.json ./
RUN npm ci --omit=dev
COPY . .
EXPOSE 3000
CMD ["node", "-e", "require('http').createServer((req,res)=>{res.writeHead(200);res.end('task-manager ok')}).listen(3000)"]
