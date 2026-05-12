FROM node:24-alpine AS build

WORKDIR /src

COPY package.json package-lock.json ./
RUN npm ci

COPY . .
RUN npm run typecheck && npx vite build --base=/client/

FROM nginx:alpine

COPY --from=build /src/dist /usr/share/nginx/html
