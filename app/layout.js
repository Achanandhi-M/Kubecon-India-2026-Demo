export const metadata = {
  title: 'Contact - Acme Corp',
  description: 'Get in touch with us',
}

export default function RootLayout({ children }) {
  return (
    <html lang="en">
      <body style={{ margin: 0, background: '#f9f9f9' }}>
        {children}
      </body>
    </html>
  )
}
