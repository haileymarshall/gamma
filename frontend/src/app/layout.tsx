import type { Metadata } from "next";
import { EB_Garamond, Schibsted_Grotesk, IBM_Plex_Mono } from "next/font/google";
import { Providers } from "@/components/Providers";
import "./globals.css";

const serif = EB_Garamond({ variable: "--font-serif-face", subsets: ["latin"], style: ["normal", "italic"] });
const sans = Schibsted_Grotesk({ variable: "--font-sans-face", subsets: ["latin"] });
const code = IBM_Plex_Mono({ variable: "--font-code", subsets: ["latin"], weight: ["400", "500", "600"] });

export const metadata: Metadata = {
  title: "GAMMA",
  description:
    "GAMMA is a token you can only mine by playing. Burn GAMMA for energies, pick a machine, and split a fixed reward every 10 minutes. Built on IMD, Uniswap v4 and drand.",
  openGraph: {
    title: "GAMMA · Mine it. Don't buy it.",
    description: "Proof-of-play mining on IMD. No team, no presale, no admin.",
  },
};

export default function RootLayout({ children }: LayoutProps<"/">) {
  return (
    <html lang="en" className={`${serif.variable} ${sans.variable} ${code.variable} antialiased`}>
      <body className="min-h-screen">
        <div className="bg-field" aria-hidden />
        <Providers>{children}</Providers>
      </body>
    </html>
  );
}
