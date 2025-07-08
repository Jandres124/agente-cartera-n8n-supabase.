-- 1. Tabla de Clientes
CREATE TABLE clients (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  name TEXT NOT NULL,
  email TEXT UNIQUE,
  phone TEXT,
  identification TEXT UNIQUE NOT NULL,
  status TEXT DEFAULT 'activo',
  created_at TIMESTAMP WITH TIME ZONE DEFAULT now()
);

-- 2. Tabla de Facturas
CREATE TABLE invoices (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  client_id UUID NOT NULL REFERENCES clients(id) ON DELETE CASCADE,
  invoice_number TEXT UNIQUE NOT NULL,
  total_amount NUMERIC(12, 2) NOT NULL,
  remaining_balance NUMERIC(12, 2) NOT NULL,
  issue_date DATE NOT NULL,
  due_date DATE NOT NULL,
  status TEXT CHECK (status IN ('unpaid', 'partially_paid', 'paid')) DEFAULT 'unpaid',
  created_at TIMESTAMP WITH TIME ZONE DEFAULT now()
);

-- 3. Tabla de Pagos
CREATE TABLE payments (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  client_id UUID NOT NULL REFERENCES clients(id) ON DELETE CASCADE,
  payment_amount NUMERIC(12, 2) NOT NULL,
  payment_date DATE NOT NULL,
  payment_method TEXT,
  notes TEXT,
  created_at TIMESTAMP WITH TIME ZONE DEFAULT now()
);

-- 4. Tabla de Estado de Cuenta
CREATE TABLE account_status (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  client_id UUID UNIQUE NOT NULL REFERENCES clients(id) ON DELETE CASCADE,
  total_due NUMERIC(12, 2) NOT NULL,
  last_updated TIMESTAMP WITH TIME ZONE DEFAULT now()
);

-- 5. Tabla de Historial de Cobranzas
CREATE TABLE collection_history (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  client_id UUID NOT NULL REFERENCES clients(id) ON DELETE CASCADE,
  action TEXT NOT NULL,
  action_date TIMESTAMP WITH TIME ZONE DEFAULT now(),
  comments TEXT
);
-- Facturas para el cliente creado
INSERT INTO invoices (client_id, invoice_number, total_amount, remaining_balance, issue_date, due_date, status)
VALUES 
  (
    (SELECT id FROM clients WHERE identification = '123456789'), -- reemplaza con la cédula real del cliente
    'INV001', 500.00, 500.00, '2025-07-01', '2025-07-10', 'unpaid'
  ),
  (
    (SELECT id FROM clients WHERE identification = '123456789'),
    'INV002', 300.00, 150.00, '2025-06-20', '2025-06-30', 'partially_paid'
  ),
  (
    (SELECT id FROM clients WHERE identification = '123456789'),
    'INV003', 200.00, 0.00, '2025-06-10', '2025-06-20', 'paid'
  );
INSERT INTO clients (name, email, identification) VALUES
('Juan Pérez', 'juanperez@email.com', '123456789'),
('Laura Rodríguez', 'laura.rodriguez@mail.com', '987654321'),
('Carlos Gómez', 'carlosg@mail.com', '456789123');


INSERT INTO invoices (client_id, invoice_number, issue_date, due_date, total_amount, remaining_balance, status) VALUES
('84c9a0bf-09d7-4077-b09f-e0b1ceb43dc6', 'INV001', '2025-07-01', '2025-07-10', 150000, 150000, 'unpaid'),
('84c9a0bf-09d7-4077-b09f-e0b1ceb43dc6', 'INV002', '2025-07-05', '2025-07-15', 85000, 85000, 'unpaid'),
('9595cce4-a3ec-4ac8-8253-9da39b4bee4b', 'INV003', '2025-07-01', '2025-07-08', 230000, 230000, 'unpaid'),
('db54f7e5-6a49-4841-abcd-c7cf96106723', 'INV004', '2025-07-05', '2025-07-20', 99000, 99000, 'unpaid'),
('db54f7e5-6a49-4841-abcd-c7cf96106723', 'INV005', '2025-06-28', '2025-07-05', 120000, 120000, 'unpaid');
-- PAGOS

INSERT INTO payments (client_id, payment_amount, payment_date, payment_method)
VALUES
  ('84c9a0bf-09d7-4077-b09f-e0b1ceb43dc6',  100000, '2025-07-07', 'transferencia'),
  ('9595cce4-a3ec-4ac8-8253-9da39b4bee4b', 75000, '2025-07-06', 'efectivo'),
  ('db54f7e5-6a49-4841-abcd-c7cf96106723',  150000, '2025-07-05', 'tarjeta');
INSERT INTO account_status (client_id, total_due, last_updated)
VALUES
  ('84c9a0bf-09d7-4077-b09f-e0b1ceb43dc6', 50000, CURRENT_TIMESTAMP),
  ('9595cce4-a3ec-4ac8-8253-9da39b4bee4b', 0, CURRENT_TIMESTAMP),
  ('db54f7e5-6a49-4841-abcd-c7cf96106723', 0, CURRENT_TIMESTAMP);
INSERT INTO collection_history (client_id, action, action_date, comments)
VALUES
  ('84c9a0bf-09d7-4077-b09f-e0b1ceb43dc6', 'correo', '2025-07-07', 'Cliente fue notificado sobre saldo pendiente.'),
  ('9595cce4-a3ec-4ac8-8253-9da39b4bee4b', 'llamada', '2025-07-06', 'Cliente prometió pago completo hoy.'),
  ('db54f7e5-6a49-4841-abcd-c7cf96106723', 'whatsapp', '2025-07-05', 'Cliente confirmó que ya pagó la factura.');
CREATE OR REPLACE FUNCTION apply_payment()
RETURNS TRIGGER AS $$
DECLARE
  v_remaining_payment NUMERIC := NEW.amount;
  v_invoice RECORD;
BEGIN
  -- 1. Validar que el monto no exceda el saldo pendiente
  IF v_remaining_payment >
    (SELECT SUM(remaining_balance)
     FROM invoices
     WHERE client_id = NEW.client_id AND status IN ('unpaid', 'partially_paid')) THEN
    RAISE EXCEPTION 'El monto del pago excede el saldo pendiente del cliente';
  END IF;

  -- 2. Aplicar el pago a facturas más antiguas (FIFO)
  FOR v_invoice IN
    SELECT * FROM invoices
    WHERE client_id = NEW.client_id AND status IN ('unpaid', 'partially_paid')
    ORDER BY issue_date ASC
  LOOP
    IF v_invoice.remaining_balance <= v_remaining_payment THEN
      -- Pago cubre completamente la factura
      v_remaining_payment := v_remaining_payment - v_invoice.remaining_balance;
      UPDATE invoices
      SET remaining_balance = 0,
          status = 'paid'
      WHERE id = v_invoice.id;
    ELSE
      -- Pago parcial
      UPDATE invoices
      SET remaining_balance = remaining_balance - v_remaining_payment,
          status = 'partially_paid'
      WHERE id = v_invoice.id;
      v_remaining_payment := 0;
    END IF;

    -- Salir si ya se usó todo el dinero
    EXIT WHEN v_remaining_payment = 0;
  END LOOP;

  -- 3. Registrar el evento en collection_history
  INSERT INTO collection_history (client_id, action, action_date, comments)
  VALUES (
    NEW.client_id,
    'pago recibido',
    NOW(),
    CONCAT('Se aplicó un pago de $', NEW.amount, ' a las facturas del cliente.')
  );

  RETURN NEW;
END;


INSERT INTO payments (client_id, payment_amount, payment_date)
VALUES ('db54f7e5-6a49-4841-abcd-c7cf96106723', 30000, '2025-07-08');
DROP TRIGGER IF EXISTS trg_apply_payment ON payments;
DROP TRIGGER IF EXISTS trg_apply_payment ON payments;

CREATE TRIGGER trg_apply_payment
AFTER INSERT ON payments
FOR EACH ROW
EXECUTE FUNCTION apply_payment();
INSERT INTO payments (client_id, payment_amount, payment_date)
VALUES ('84c9a0bf-09d7-4077-b09f-e0b1ceb43dc6', 20000, '2025-07-08');

