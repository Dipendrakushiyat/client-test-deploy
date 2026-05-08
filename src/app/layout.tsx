import type { Metadata } from "next";
import "./globals.css";

export const metadata: Metadata = {
  title: "Contact Manager",
  description: "Simple contact management app",
};

export default function RootLayout({
  children,
}: Readonly<{
  children: React.ReactNode;
}>) {
  return (
    <html lang="en">
      <body>{children}</body>
    </html>
  );
}
