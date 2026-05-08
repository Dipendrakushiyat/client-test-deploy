# Contact Management App

Simple contact management app built with Next.js, Prisma, and PostgreSQL.

## Run with Docker

```bash
docker compose up --build
```

Open http://localhost:3000

## Local run (without Docker)

1. Update `DATABASE_URL` in `.env` to your local PostgreSQL connection.
2. Run:

```bash
npm install
npx prisma db push
npm run dev
```
