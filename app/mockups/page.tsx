"use client";

import { useState } from "react";

type Category = "restaurant" | "bar" | "cafe" | "bakery" | "dessert";
type Sentiment = "liked" | "okay" | "didnt-like";

type Candidate = {
  id: string;
  name: string;
  city: string;
  clarifying: boolean;
  note: string;
  category: Category | "";
  sentiment: Sentiment | "";
  sent: boolean;
};

const initialCandidates: Candidate[] = [
  {
    id: "uovo",
    name: "Uovo",
    city: "Los Angeles",
    clarifying: false,
    note: "",
    category: "",
    sentiment: "",
    sent: false,
  },
  {
    id: "khao-tiew",
    name: "Khao Tiew",
    city: "San Francisco",
    clarifying: false,
    note: "",
    category: "",
    sentiment: "",
    sent: false,
  },
  {
    id: "in-n-out",
    name: "In N Out",
    city: "Santa Barbara",
    clarifying: false,
    note: "",
    category: "",
    sentiment: "",
    sent: false,
  },
];

const categories: Array<{ value: Category; label: string }> = [
  { value: "restaurant", label: "Restaurant" },
  { value: "bar", label: "Bar" },
  { value: "cafe", label: "Cafe" },
  { value: "bakery", label: "Bakery" },
  { value: "dessert", label: "Dessert" },
];

const sentimentOptions: Array<{ value: Sentiment; label: string }> = [
  { value: "liked", label: "I liked it" },
  { value: "okay", label: "It was ok" },
  { value: "didnt-like", label: "I didn't like it" },
];

const activityItems = [
  { id: "grouping", label: "Grouping photos by location...", state: "working" },
  { id: "found", label: "Khao Tiew in San Francisco", state: "ready" },
  { id: "checking", label: "Checking another cluster...", state: "working" },
];

const workflowSteps = [
  "Grouping photos by location",
  "Checking restaurant matches",
  "Waiting for your review",
  "Ready to send to phone",
];

function isCandidateReady(candidate: Candidate) {
  return Boolean(candidate.category && candidate.sentiment);
}

function PhotoStack({ size = "small" }: { size?: "small" | "large" }) {
  return (
    <span className={`photo-stack photo-stack--${size}`} aria-hidden="true">
      <span className="photo-stack__back" />
      <span className="photo-stack__middle" />
      <span className="photo-stack__front" />
    </span>
  );
}

function PanelLabel({ children }: { children: React.ReactNode }) {
  return <p className="panel-label">{children}</p>;
}

export default function Home() {
  const [uploaded, setUploaded] = useState(false);
  const [selectedActivity, setSelectedActivity] = useState("found");
  const [candidates, setCandidates] = useState(initialCandidates);
  const [workflowStep, setWorkflowStep] = useState(0);

  const readyCount = candidates.filter(isCandidateReady).length;
  const sentCount = candidates.filter((candidate) => candidate.sent).length;

  const toggleClarifying = (id: string) => {
    setCandidates((current) =>
      current.map((candidate) =>
        candidate.id === id
          ? { ...candidate, clarifying: !candidate.clarifying }
          : candidate,
      ),
    );
  };

  const updateNote = (id: string, note: string) => {
    setCandidates((current) =>
      current.map((candidate) =>
        candidate.id === id ? { ...candidate, note } : candidate,
      ),
    );
  };

  const updateCategory = (id: string, category: Category | "") => {
    setCandidates((current) =>
      current.map((candidate) =>
        candidate.id === id ? { ...candidate, category, sent: false } : candidate,
      ),
    );
  };

  const updateSentiment = (id: string, sentiment: Sentiment) => {
    setCandidates((current) =>
      current.map((candidate) =>
        candidate.id === id ? { ...candidate, sentiment, sent: false } : candidate,
      ),
    );
  };

  const sendCandidate = (id: string) => {
    setCandidates((current) =>
      current.map((candidate) =>
        candidate.id === id && isCandidateReady(candidate)
          ? { ...candidate, sent: true }
          : candidate,
      ),
    );
  };

  const sendReadyCandidates = () => {
    setCandidates((current) =>
      current.map((candidate) =>
        isCandidateReady(candidate) ? { ...candidate, sent: true } : candidate,
      ),
    );
  };

  const resetPrototype = () => {
    setUploaded(false);
    setSelectedActivity("found");
    setCandidates(initialCandidates);
    setWorkflowStep(0);
  };

  return (
    <main className="app-shell">
      <header className="app-header">
        <div>
          <p className="brand">Beli</p>
          <p className="brand-caption">cluster, review, send</p>
        </div>
        <div className="header-actions">
          <span className="prototype-status">
            <span className="status-dot" aria-hidden="true" />
            mock flow
          </span>
          <button className="reset-button" type="button" onClick={resetPrototype}>
            reset
          </button>
        </div>
      </header>

      <section className="prototype-grid" aria-label="Beli prototype screens">
        <section className="panel upload-panel">
          <PanelLabel>Input</PanelLabel>
          <button
            className={`drop-zone ${uploaded ? "drop-zone--ready" : ""}`}
            type="button"
            aria-pressed={uploaded}
            onClick={() => setUploaded((current) => !current)}
          >
            {uploaded ? (
              <>
                <PhotoStack size="large" />
                <span className="drop-zone__title">Photos ready</span>
                <span className="drop-zone__hint">click to clear the mock upload</span>
              </>
            ) : (
              <>
                <span className="drop-zone__title">Drop photos here</span>
                <span className="drop-zone__hint">click anywhere to simulate an upload</span>
              </>
            )}
          </button>
        </section>

        <section className="panel activity-panel">
          <div className="panel-heading">
            <div>
              <PanelLabel>Search</PanelLabel>
              <h1>Finding the places</h1>
            </div>
            <span className="panel-note">live feed</span>
          </div>
          <div className="activity-list">
            {activityItems.map((item) => (
              <button
                className={`activity-row ${selectedActivity === item.id ? "is-selected" : ""}`}
                type="button"
                key={item.id}
                onClick={() => setSelectedActivity(item.id)}
              >
                <PhotoStack />
                <span className="activity-row__label">{item.label}</span>
                <span className={`activity-row__state activity-row__state--${item.state}`}>
                  {selectedActivity === item.id ? "viewing" : item.state}
                </span>
              </button>
            ))}
          </div>
        </section>

        <section className="panel review-panel">
          <div className="panel-heading">
            <div>
              <PanelLabel>Review</PanelLabel>
              <h1>Check each photo cluster</h1>
            </div>
            <span className="panel-note">category and feeling</span>
          </div>
          <div className="candidate-list">
            {candidates.map((candidate) => {
              const ready = isCandidateReady(candidate);

              return (
                <div className="candidate-row" key={candidate.id}>
                  <PhotoStack />
                  <div className="candidate-main">
                    <div className="candidate-topline">
                      <div className="candidate-info">
                        <span className="candidate-name">{candidate.name}</span>
                        <span className="candidate-city">{candidate.city}</span>
                      </div>
                      <div className="row-actions">
                        <button
                          className="quiet-button"
                          type="button"
                          onClick={() => toggleClarifying(candidate.id)}
                        >
                          {candidate.clarifying ? "Save" : "Clarify"}
                        </button>
                        <button
                          className={`quiet-button ${candidate.sent ? "is-selected" : ""}`}
                          type="button"
                          disabled={!ready}
                          aria-disabled={!ready}
                          aria-pressed={candidate.sent}
                          onClick={() => sendCandidate(candidate.id)}
                        >
                          {candidate.sent ? "Sent" : "Rank"}
                        </button>
                      </div>
                    </div>

                    <div className="review-controls">
                      <label className="category-field">
                        <span>Category</span>
                        <select
                          className="category-select"
                          value={candidate.category}
                          aria-label={`Category for ${candidate.name}`}
                          onChange={(event) =>
                            updateCategory(candidate.id, event.target.value as Category | "")
                          }
                        >
                          <option value="">Choose one</option>
                          {categories.map((category) => (
                            <option value={category.value} key={category.value}>
                              {category.label}
                            </option>
                          ))}
                        </select>
                      </label>
                      <div className="sentiment-field">
                        <span>Feeling</span>
                        <div
                          className="sentiment-picker"
                          role="group"
                          aria-label={`Feeling for ${candidate.name}`}
                        >
                          {sentimentOptions.map((option) => (
                            <button
                              className={`sentiment-button ${candidate.sentiment === option.value ? "is-selected" : ""}`}
                              type="button"
                              key={option.value}
                              aria-pressed={candidate.sentiment === option.value}
                              onClick={() => updateSentiment(candidate.id, option.value)}
                            >
                              {option.label}
                            </button>
                          ))}
                        </div>
                      </div>
                    </div>

                    {candidate.clarifying ? (
                      <input
                        className="clarify-input"
                        value={candidate.note}
                        onChange={(event) => updateNote(candidate.id, event.target.value)}
                        placeholder="What should this be called?"
                        aria-label={`Clarify ${candidate.name}`}
                      />
                    ) : null}
                  </div>
                </div>
              );
            })}
          </div>
        </section>

        <section className="panel send-panel">
          <div className="panel-heading">
            <div>
              <PanelLabel>Ready to send</PanelLabel>
              <h1>Let your phone rank it</h1>
            </div>
            <span className="panel-note">{sentCount ? "sent to phone" : "mock control"}</span>
          </div>
          <div className="send-list">
            {candidates.map((candidate) => {
              const ready = isCandidateReady(candidate);
              const status = candidate.sent
                ? "sent to phone"
                : ready
                  ? "ready to rank"
                  : "needs review";

              return (
                <div className="send-row" key={candidate.id}>
                  <PhotoStack />
                  <div className="send-info">
                    <span className="candidate-name">{candidate.name}</span>
                    <span className={`send-status send-status--${candidate.sent ? "sent" : ready ? "ready" : "waiting"}`}>
                      {status}
                    </span>
                  </div>
                </div>
              );
            })}
          </div>
          <button
            className="rank-all-button"
            type="button"
            disabled={!readyCount}
            onClick={sendReadyCandidates}
          >
            {readyCount ? "Rank ready" : "Review something first"}
          </button>
        </section>

        <section className="panel process-panel">
          <div className="process-graphic">
            <PhotoStack size="large" />
          </div>
          <div className="process-copy">
            <div className="panel-heading process-heading">
              <div>
                <PanelLabel>Process</PanelLabel>
                <h1>From photos to shortlist</h1>
              </div>
              <span className="panel-note">mocked</span>
            </div>
            <div className="workflow-list">
              {workflowSteps.map((step, index) => {
                const state = index < workflowStep ? "complete" : index === workflowStep ? "active" : "pending";
                return (
                  <button
                    className={`workflow-line workflow-line--${state}`}
                    type="button"
                    key={step}
                    onClick={() => setWorkflowStep(index)}
                  >
                    <span className="workflow-line__marker" aria-hidden="true" />
                    <span>{step}</span>
                  </button>
                );
              })}
            </div>
            <button
              className="advance-button"
              type="button"
              onClick={() => setWorkflowStep((current) => (current + 1) % workflowSteps.length)}
            >
              Advance mock flow
            </button>
          </div>
        </section>
      </section>
    </main>
  );
}
