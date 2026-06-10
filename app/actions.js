'use server'

export async function submitContact(formData) {
  const message = formData.get('message')
  return { received: message }
}
