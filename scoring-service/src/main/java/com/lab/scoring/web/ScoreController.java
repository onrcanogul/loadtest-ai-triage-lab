package com.lab.scoring.web;

import com.lab.scoring.service.ScoringService;
import com.lab.scoring.web.dto.ScoreRequest;
import com.lab.scoring.web.dto.ScoreResponse;
import jakarta.validation.Valid;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.slf4j.MDC;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;

@RestController
@RequestMapping("/api/v1/scores")
public class ScoreController {

    private static final Logger log = LoggerFactory.getLogger(ScoreController.class);

    private final ScoringService scoringService;

    public ScoreController(ScoringService scoringService) {
        this.scoringService = scoringService;
    }

    @PostMapping
    public ScoreResponse score(@Valid @RequestBody ScoreRequest request) {
        MDC.put("customerId", request.customerId());
        int score = scoringService.score(request.customerId());
        log.info("score computed score={}", score);
        return new ScoreResponse(request.customerId(), score);
    }
}
