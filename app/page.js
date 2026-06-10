import { submitContact } from './actions'

export default function Home() {
  return (
    <main style={{
      fontFamily: 'sans-serif',
      maxWidth: '600px',
      margin: '80px auto',
      padding: '40px',
      border: '1px solid #eee',
      borderRadius: '8px',
      boxShadow: '0 2px 8px rgba(0,0,0,0.08)'
    }}>
      <h1 style={{ marginBottom: '8px' }}>Contact Us</h1>
      <p style={{ color: '#666', marginBottom: '24px' }}>
        Send us a message and we will get back to you shortly.
      </p>
      <form action={submitContact}>
        <input
          name="message"
          placeholder="Your message..."
          style={{
            width: '100%',
            padding: '12px',
            marginBottom: '12px',
            display: 'block',
            border: '1px solid #ddd',
            borderRadius: '4px',
            fontSize: '14px',
            boxSizing: 'border-box'
          }}
        />
        <button
          type="submit"
          style={{
            padding: '12px 24px',
            background: '#0070f3',
            color: 'white',
            border: 'none',
            borderRadius: '4px',
            fontSize: '14px',
            cursor: 'pointer'
          }}
        >
          Send Message
        </button>
      </form>
    </main>
  )
}
