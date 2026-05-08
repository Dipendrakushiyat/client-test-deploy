import { revalidatePath } from "next/cache";
import { prisma } from "@/lib/prisma";

export const dynamic = "force-dynamic";

async function createContact(formData: FormData) {
  "use server";

  await prisma.contact.create({
    data: {
      name: String(formData.get("name") ?? ""),
      number: String(formData.get("number") ?? ""),
      email: String(formData.get("email") ?? ""),
      address: String(formData.get("address") ?? ""),
    },
  });

  revalidatePath("/");
}

async function deleteContact(formData: FormData) {
  "use server";

  const id = Number(formData.get("id"));
  await prisma.contact.delete({ where: { id } });
  revalidatePath("/");
}

export default async function HomePage() {
  const contacts = await prisma.contact.findMany({
    orderBy: { id: "desc" },
  });

  return (
    <main className="container">
      <h1>Contact Management</h1>

      <form action={createContact} className="form">
        <input name="name" placeholder="Name" />
        <input name="number" placeholder="Number" />
        <input name="email" placeholder="Email" />
        <input name="address" placeholder="Address" />
        <button type="submit">Add Contact</button>
      </form>

      <table>
        <thead>
          <tr>
            <th>Name</th>
            <th>Number</th>
            <th>Email</th>
            <th>Address</th>
            <th>Action</th>
          </tr>
        </thead>
        <tbody>
          {contacts.map((contact) => (
            <tr key={contact.id}>
              <td>{contact.name}</td>
              <td>{contact.number}</td>
              <td>{contact.email}</td>
              <td>{contact.address}</td>
              <td>
                <form action={deleteContact}>
                  <input type="hidden" name="id" value={contact.id} />
                  <button type="submit">Delete</button>
                </form>
              </td>
            </tr>
          ))}
          {contacts.length === 0 ? (
            <tr>
              <td colSpan={5}>No contacts yet.</td>
            </tr>
          ) : null}
        </tbody>
      </table>
    </main>
  );
}
