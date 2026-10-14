// Command echo is a minimal Converger agent: it echoes every user turn and
// asks for confirmation when the user writes "refund".
//
//	CONVERGER_URL=http://localhost:4000 CONVERGER_TOKEN=<channel-scoped token> go run ./examples/echo
package main

import (
	"context"
	"fmt"
	"log"
	"os"
	"os/signal"

	agent "github.com/AimTune/converger/packages/agent-go"
)

func main() {
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt)
	defer stop()

	a := agent.New(agent.SocketURL(os.Getenv("CONVERGER_URL")),
		agent.StaticToken(os.Getenv("CONVERGER_TOKEN")),
		agent.OnError(func(err error) { log.Printf("agent: %v", err) }))

	a.OnTurn(func(ctx context.Context, turn *agent.Turn, reply *agent.Reply) error {
		log.Printf("turn %s #%d: %q", turn.ConversationID, turn.Seq, turn.Text)
		if turn.Text == "refund" {
			answer, err := reply.Ask(ctx, map[string]any{"title": "Refund 249.90 TRY?"},
				agent.Action{Label: "Yes", Value: "yes"}, agent.Action{Label: "No", Value: "no"})
			if err != nil {
				return err
			}
			_, err = reply.Text(ctx, fmt.Sprintf("You answered %v.", answer))
			return err
		}
		if err := reply.Typing(ctx, true); err != nil {
			return err
		}
		_, err := reply.Text(ctx, "You said: "+turn.Text)
		return err
	})

	if err := a.Run(ctx); err != nil {
		log.Fatal(err)
	}
}
