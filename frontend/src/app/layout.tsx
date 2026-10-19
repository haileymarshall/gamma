import type { Metadata } from "next";
import { Space_Grotesk, JetBrains_Mono } from "next/font/google";
import { Providers } from "@/components/Providers";
import "./globals.css";

const display = Space_Grotesk({ variable: "--font-display", subsets: ["latin"] });
const code = JetBrains_Mono({ variable: "--font-code", subsets: ["latin"] });

export const metadata: Metadata = {
  title: "GAMMA · Mine it. Don't buy it.",
  description:
    "GAMMA is a token you can only mine by playing. Burn GAMMA for energies, pick a machine, and split a fixed reward every 10 minutes. Built on IMD, Uniswap v4 and drand.",
  openGraph: {
    title: "GAMMA · Mine it. Don't buy it.",
    description: "Proof-of-play mining on IMD. No team, no presale, no admin.",
  },
};

export default function RootLayout({ children }: LayoutProps<"/">) {
  return (
    <html lang="en" className={`${display.variable} ${code.variable} antialiased`}>
      <body className="min-h-screen">
        <div className="bg-field" aria-hidden />
        <Providers>{children}</Providers>
      </body>
    </html>
  );
}
